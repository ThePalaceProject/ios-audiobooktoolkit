//
//  PartialArchiveCachingHTTPClient.swift
//  PalaceAudiobookToolkit
//
//  Keeps the bytes Readium reads of a remote LCP archive instead of
//  discarding them, so a read-ahead becomes download progress (PP-5367).
//

import Foundation
import os
import ReadiumShared

/// Decision trace for the partial-archive cache.
///
/// A dedicated subsystem rather than `ATLog` or Readium's `log()`: the former
/// throttles by message prefix and drops `.debug` in DEBUG builds, and the
/// latter's sink belongs to the host app. Read it with
/// `log stream --predicate 'subsystem == "org.thepalaceproject.lcpcache"'`.
let lcpCacheLog = OSLog(subsystem: "org.thepalaceproject.lcpcache", category: "decisions")

// MARK: - What the client needs from a byte-range store

/// The part of a partial-archive store this client uses.
///
/// A protocol rather than the concrete store so the client can be driven in a
/// test without touching a disk, and so the two can land independently. Every
/// member uses only standard-library types, so `PartialArchiveStore` satisfies
/// it as written.
public protocol ArchiveRangeStore: AnyObject, Sendable {
  var totalSize: UInt64 { get }
  func missingRanges(in range: Range<UInt64>) -> [Range<UInt64>]
  @discardableResult
  func write(_ bytes: Data, at offset: UInt64) throws -> Range<UInt64>
  func read(_ range: Range<UInt64>) throws -> Data
}

/// Opens the store for an archive.
///
/// Called with a length once a response's `Content-Range` has reported
/// one, and with nil before then, which asks for a store only if one
/// already exists on disk: otherwise the first read of a book read
/// before would fetch bytes it already holds just to learn how long the
/// archive is. Returning nil means not available yet, and is not an
/// error. The factory also owns the policy for an archive whose recorded
/// length no longer matches, delete and start over, because that is a
/// data decision and not this client's.
public typealias ArchiveRangeStoreFactory = (HTTPURL, UInt64?) throws -> ArchiveRangeStore?

// MARK: - PartialArchiveCachingHTTPClient

/// An `HTTPClient` that serves byte ranges of a remote archive from a local
/// store, and records every range it does fetch.
///
/// This is the layer the money is spent at. Readium's
/// `ZIPFoundationArchiveFactory` buffers a remote archive at 6 MB, so every
/// read that misses its window costs a whole 6 MB range request — measured as
/// three such fills, 18,874,368 bytes, before the first audio sample of a cold
/// chapter, and measured again with the player's own per-track buffer switched
/// off to confirm the fills come from below it. Those bytes are part of the
/// archive the app separately downloads, so keeping them makes the read-ahead
/// pay for itself twice: the request count stays low AND the bytes are not
/// fetched again.
///
/// Raw archive bytes at absolute archive offsets, which is why this sits here
/// and not in the player's resource loader: that loader is handed the
/// LCP-decrypted bytes of one ZIP entry at entry-relative offsets, which are
/// not archive bytes and cannot be assembled into an archive.
public final class PartialArchiveCachingHTTPClient: HTTPClient, Loggable {

  // MARK: - Decisions

  /// What to do with one request.
  public enum CacheDecision: Equatable {
    /// Every byte asked for is already local.
    case serveFromStore(Range<UInt64>)
    /// Fetch it, and record what comes back.
    case fetchAndStore(Range<UInt64>)
    /// Fetch only the parts of the window that are not local, then answer
    /// the whole window from the store.
    ///
    /// Readium's archive buffer re-asks for a window shifted a little from
    /// one it already filled, so most of what it asks for is usually
    /// already here. `maxGapRequestsPerRead` bounds when this is worth it.
    case fillGaps(requested: Range<UInt64>, missing: [Range<UInt64>])

    /// Hand it to the upstream client untouched. The reason is logged, not
    /// branched on.
    case passThrough(reason: String)
  }

  /// Whether a response may be written to the store, and at what offset.
  public enum StoreAdmission: Equatable {
    case store(at: UInt64)
    case reject(reason: String)
  }

  /// A parsed `Content-Range` response header.
  public struct ContentRange: Equatable {
    public let start: UInt64
    /// Inclusive, as the header states it.
    public let end: UInt64
    /// `nil` for `*`, which a server may send when it does not know.
    public let totalSize: UInt64?

    public var length: UInt64 { end >= start ? end - start + 1 : 0 }
  }

  /// Largest range this client will hold in memory in order to validate the
  /// response before storing it.
  ///
  /// Nothing may be written until the status and `Content-Range` have been
  /// checked, and Readium's API only yields those when the response completes,
  /// so a cacheable range is accumulated first. Sized just above Readium's
  /// 6 MB archive window, which is the request shape that costs money;
  /// anything larger passes through uncached rather than being buffered.
  public static let defaultMaxCacheableRangeLength = 8 * 1024 * 1024

  /// How many cacheable requests may be accumulating at once.
  ///
  /// The resource loader admits eight concurrent requests, and eight buffered
  /// windows would be 64 MB of transient memory on a device that already has a
  /// backgrounded out-of-memory crash on record. Beyond this many, requests
  /// pass through uncached: slower to fill the archive, never incorrect.
  public static let defaultMaxConcurrentCachedRequests = 2

  /// How many separate gap requests one read may be split into.
  ///
  /// Each gap is its own round trip, so a window broken into many pieces
  /// is cheaper to refetch whole than to stitch. This bounds the trade at
  /// the shape that actually occurs: one gap at the leading edge of a
  /// window Readium shifted backwards.
  public static let defaultMaxGapRequestsPerRead = 4

  /// Gaps are fetched separately only when doing so at least halves the
  /// bytes moved. Below that the saving does not pay for the extra round
  /// trips and a whole-window fetch is both simpler and faster.
  public static let gapFillMaxMissingFraction = 2

  /// How long a store-open failure is honoured before another attempt.
  ///
  /// A failure to open the store is usually transient — a momentary disk
  /// error, a brief ENOSPC — so refusing the archive for the rest of the
  /// process costs every later chapter window a full refetch from the origin.
  /// Retrying on every request is the other extreme: each attempt is blocking
  /// file I/O in front of the patron's audio. An interval is the middle: one
  /// attempt per window-read burst, and the cache heals itself once the
  /// condition clears.
  public static let defaultStoreRetryInterval: TimeInterval = 30

  private let upstream: HTTPClient
  private let storeFactory: ArchiveRangeStoreFactory
  private let maxCacheableRangeLength: Int
  private let maxConcurrentCachedRequests: Int
  private let maxGapRequestsPerRead: Int
  private let storeRetryInterval: TimeInterval
  private let monotonicNow: @Sendable () -> TimeInterval

  /// Store calls are synchronous blocking file I/O. Reached from `stream`,
  /// which is `async`, so they are hopped onto this queue rather than run
  /// inline: blocking a cooperative thread would stall unrelated work.
  private let storeQueue = DispatchQueue(
    label: "com.palace.partial-archive-store",
    qos: .userInitiated
  )

  private let lock = NSLock()
  private var stores: [String: ArchiveRangeStore] = [:]
  /// Monotonic time before which this archive's store is not reopened.
  private var storeRetryNotBefore: [String: TimeInterval] = [:]
  private var cachedRequestsInFlight = 0

  public init(
    upstream: HTTPClient,
    storeFactory: @escaping ArchiveRangeStoreFactory,
    maxCacheableRangeLength: Int = PartialArchiveCachingHTTPClient.defaultMaxCacheableRangeLength,
    maxConcurrentCachedRequests: Int = PartialArchiveCachingHTTPClient
      .defaultMaxConcurrentCachedRequests,
    maxGapRequestsPerRead: Int = PartialArchiveCachingHTTPClient
      .defaultMaxGapRequestsPerRead,
    storeRetryInterval: TimeInterval = PartialArchiveCachingHTTPClient
      .defaultStoreRetryInterval,
    // Monotonic, not wall clock: an NTP correction or a user clock change can
    // move `Date()` by hours, which would either strand the archive uncached
    // or reopen it on every request. Injectable so the retry bound is driven
    // deterministically in a test rather than by a real sleep.
    monotonicNow: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.upstream = upstream
    self.storeFactory = storeFactory
    self.maxCacheableRangeLength = maxCacheableRangeLength
    self.maxConcurrentCachedRequests = maxConcurrentCachedRequests
    self.maxGapRequestsPerRead = maxGapRequestsPerRead
    self.storeRetryInterval = storeRetryInterval
    self.monotonicNow = monotonicNow
  }

  // MARK: - Pure decisions

  /// Parses a `Content-Range` value such as `bytes 0-6291455/1630000000`.
  ///
  /// Returns nil for anything it does not fully understand, including a unit
  /// other than `bytes` and the unsatisfied-range form `bytes * /1234`: a
  /// header this client cannot read is a header it must not write bytes on.
  public static func parseContentRange(_ value: String) -> ContentRange? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
    let spec = trimmed.dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
    let halves = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard halves.count == 2 else { return nil }
    // `bytes */1234` answers an unsatisfiable request and names no bytes.
    guard halves[0] != "*" else { return nil }
    let bounds = halves[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2,
          let start = UInt64(bounds[0]),
          let end = UInt64(bounds[1]),
          end >= start
    else { return nil }
    let total: UInt64?
    if halves[1] == "*" {
      total = nil
    } else if let parsed = UInt64(halves[1]) {
      total = parsed
    } else {
      return nil
    }
    return ContentRange(start: start, end: end, totalSize: total)
  }

  /// Whether a response to a range request may be stored.
  ///
  /// A 200 means the server ignored `Range` and sent the whole object, which
  /// `HTTPResource.stream` reports as success because it only checks whether
  /// fewer bytes arrived than expected. Writing that body at the requested
  /// offset would put the head of the archive in the middle of it, so the
  /// status and the echoed range are both required before a single byte is
  /// written.
  ///
  /// A server may legitimately answer with a SHORTER range than asked for, so
  /// the offset is what must match; the body is then checked against the length
  /// the header itself claims, because that is the only statement about which
  /// bytes these are.
  public static func admitResponse(
    status: Int,
    contentRange: String?,
    requested: Range<UInt64>,
    bodyLength: Int
  ) -> StoreAdmission {
    guard status == 206 else {
      return .reject(reason: "status \(status) is not a partial response")
    }
    guard let contentRange else {
      return .reject(reason: "no Content-Range header")
    }
    guard let parsed = parseContentRange(contentRange) else {
      return .reject(reason: "Content-Range could not be read")
    }
    guard parsed.start == requested.lowerBound else {
      return .reject(reason: "Content-Range start does not match the requested offset")
    }
    guard UInt64(bodyLength) == parsed.length else {
      return .reject(reason: "body length does not match Content-Range")
    }
    return .store(at: parsed.start)
  }

  /// What to do with a request, given what the store already holds.
  ///
  /// `missing` is nil when no store is open yet for this archive — the first
  /// request of a session, whose response is what reveals the archive's
  /// length.
  public static func decide(
    isRangedGET: Bool,
    requested: Range<UInt64>?,
    missing: [Range<UInt64>]?,
    maxCacheableRangeLength: Int,
    hasCacheSlot: Bool,
    maxGapRequestsPerRead: Int = PartialArchiveCachingHTTPClient.defaultMaxGapRequestsPerRead,
    gapFillMaxMissingFraction: Int = PartialArchiveCachingHTTPClient.gapFillMaxMissingFraction
  ) -> CacheDecision {
    guard isRangedGET, let requested, !requested.isEmpty else {
      return .passThrough(reason: "not a ranged GET")
    }
    // Neither cap applies: a served range is delivered in chunks of at most
    // `maxCacheableRangeLength`, so its span does not set the buffer, and it
    // reserves no slot because it makes no upstream request.
    if let missing, missing.isEmpty {
      return .serveFromStore(requested)
    }
    guard requested.count <= maxCacheableRangeLength else {
      return .passThrough(reason: "range is larger than the memory cap for validation")
    }
    guard hasCacheSlot else {
      return .passThrough(reason: "too many cacheable requests already in flight")
    }
    // A window that is mostly local costs its gaps, not its whole span.
    // Readium shifts its 6 MB archive window by a fraction of itself
    // between reads, so the overlap is usually nearly the whole window.
    if let missing,
       !missing.isEmpty,
       missing.count <= maxGapRequestsPerRead,
       missing.reduce(0) { $0 + $1.count } * gapFillMaxMissingFraction <= requested.count {
      return .fillGaps(requested: requested, missing: missing)
    }
    return .fetchAndStore(requested)
  }

  /// The range a request asks for, or nil when it asks for no range or for one
  /// this client cannot bound.
  ///
  /// `HTTPRequest.setRange` writes an open-ended `bytes=start-` when it wants
  /// everything from an offset. That is bounded only once the archive's length
  /// is known, so before then such a request passes through.
  static func requestedRange(rangeHeader: String?, knownTotalSize: UInt64?) -> Range<UInt64>? {
    guard let rangeHeader else { return nil }
    let trimmed = rangeHeader.trimmingCharacters(in: .whitespaces).lowercased()
    guard trimmed.hasPrefix("bytes=") else { return nil }
    let spec = trimmed.dropFirst("bytes=".count)
    // A multi-range request names several spans; this client handles one.
    guard !spec.contains(",") else { return nil }
    let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = UInt64(bounds[0]) else { return nil }
    if bounds[1].isEmpty {
      guard let knownTotalSize, knownTotalSize > start else { return nil }
      return start ..< knownTotalSize
    }
    guard let last = UInt64(bounds[1]), last >= start else { return nil }
    return start ..< last + 1
  }

  // MARK: - Diagnosing a slow open

  /// What this client has asked the origin for, and what it answered from the
  /// store, since it was created.
  ///
  /// Monotonic for the client's lifetime: a caller snapshots it either side of
  /// an operation and reports the delta. It exists because a slow publication
  /// open is opaque from the app — `PublicationOpener.open` is a single await —
  /// and the question that separates its candidate causes is how many ranged
  /// requests the archive reads cost. One or two means the time went to licence
  /// validation; many for a few megabytes served means the reads are
  /// refetching the same windows.
  public struct UpstreamActivity: Sendable, Equatable {
    public let originRequests: Int
    public let originBytes: Int
    public let storeServes: Int
    public let storeBytes: Int

    public func delta(since earlier: UpstreamActivity) -> UpstreamActivity {
      UpstreamActivity(
        originRequests: originRequests - earlier.originRequests,
        originBytes: originBytes - earlier.originBytes,
        storeServes: storeServes - earlier.storeServes,
        storeBytes: storeBytes - earlier.storeBytes
      )
    }
  }

  private let activityLock = NSLock()
  private var _activity = UpstreamActivity(originRequests: 0, originBytes: 0, storeServes: 0, storeBytes: 0)

  public var upstreamActivity: UpstreamActivity {
    activityLock.lock()
    defer { activityLock.unlock() }
    return _activity
  }

  private func recordOriginRequest(bytes: Int) {
    activityLock.lock()
    _activity = UpstreamActivity(
      originRequests: _activity.originRequests + 1,
      originBytes: _activity.originBytes + bytes,
      storeServes: _activity.storeServes,
      storeBytes: _activity.storeBytes
    )
    activityLock.unlock()
  }

  private func recordStoreServe(bytes: Int) {
    activityLock.lock()
    _activity = UpstreamActivity(
      originRequests: _activity.originRequests,
      originBytes: _activity.originBytes,
      storeServes: _activity.storeServes + 1,
      storeBytes: _activity.storeBytes + bytes
    )
    activityLock.unlock()
  }

  /// Every origin request goes through here, so `upstreamActivity` cannot
  /// drift from what was actually fetched.
  private func streamFromOrigin(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    let fetched = LockIsolated(0)
    let result = await upstream.stream(request: request) { data, progress in
      fetched.withValue { $0 += data.count }
      return consume(data, progress)
    }
    recordOriginRequest(bytes: fetched.value)
    return result
  }

  // MARK: - HTTPClient

  public func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return await streamFromOrigin(request: request, consume: consume)
    }
    let key = req.url.string
    let store = openStore(for: key)
    let requested = Self.requestedRange(
      rangeHeader: req.headers.first { $0.key.lowercased() == "range" }?.value,
      knownTotalSize: store?.totalSize
    )

    let missing: [Range<UInt64>]? = await {
      guard let store, let requested else { return nil }
      return await onStoreQueue { store.missingRanges(in: requested) }
    }()

    let reserved = reserveCacheSlot()
    let decision = Self.decide(
      isRangedGET: req.method == .get,
      requested: requested,
      missing: missing,
      maxCacheableRangeLength: maxCacheableRangeLength,
      hasCacheSlot: reserved,
      maxGapRequestsPerRead: maxGapRequestsPerRead
    )
    switch decision {
    case .fetchAndStore, .fillGaps:
      break
    case .serveFromStore, .passThrough:
      if reserved { releaseCacheSlot() }
    }

    switch decision {
    case let .passThrough(reason):
      // .info, not .debug: ATLog drops .debug in DEBUG builds, and a cache
      // whose decisions cannot be observed is one nobody can tune or trust.
      // These lines are the only evidence the client is installed and working.
      os_log("LCPCACHE through %{public}@", log: lcpCacheLog, type: .default, String(describing: reason))
      return await streamFromOrigin(request: req, consume: consume)

    case let .serveFromStore(range):
      os_log("LCPCACHE hit %{public}llu-%{public}llu %{public}d", log: lcpCacheLog, type: .default,
             range.lowerBound, range.upperBound, range.count)
      guard let store else {
        return await streamFromOrigin(request: req, consume: consume)
      }
      // Presence is confirmed from the journal, which costs no buffer, BEFORE
      // any byte is handed to `consume`. Once a chunk has been delivered the
      // request can no longer be restarted upstream without serving those
      // bytes twice, so the check that used to be "read it all and compare
      // lengths" has to happen first instead.
      let stillMissing = await onStoreQueue({ store.missingRanges(in: range) })
      guard stillMissing.isEmpty else {
        // The record and the file disagree. Never serve what we cannot prove
        // we hold — a hole reads back as zeros of the right length and nothing
        // downstream would notice. Go to the origin instead.
        log(.warning, "partial archive cache: a range recorded present is no longer held — refetching")
        return await streamFromOrigin(request: req, consume: consume)
      }

      // Served in chunks rather than as one `Data`. Readium asks for
      // everything from an offset with an open-ended `bytes=start-`, which
      // `requestedRange` resolves to the archive's full length, so a
      // fully-present tail of a 1-2 GB archive was a single allocation of that
      // size — in a client that caps every other buffer at
      // `maxCacheableRangeLength` because this device has a backgrounded
      // out-of-memory crash on record.
      var servedCount = 0
      var cursor = range.lowerBound
      while cursor < range.upperBound {
        let want = Int(min(UInt64(maxCacheableRangeLength), range.upperBound - cursor))
        let chunkRange = cursor ..< cursor + UInt64(want)
        let chunk = await onStoreQueue({ try? store.read(chunkRange) })
        guard let chunk, chunk.count == want else {
          if servedCount == 0 {
            log(.warning, "partial archive cache: a range recorded present could not be read — refetching")
            return await streamFromOrigin(request: req, consume: consume)
          }
          // Bytes are already downstream, so the origin cannot be used without
          // duplicating them. Fail the request and let the caller reissue it.
          log(.warning, "partial archive cache: a served range became unreadable part way through — failing the request")
          let unreadable = PartialArchiveStoreError.notPresent(missing: [chunkRange])
          return .failure(.other(unreadable))
        }
        if case let .failure(error) = consume(chunk, Double(servedCount + chunk.count) / Double(range.count)) {
          return .failure(error)
        }
        servedCount += chunk.count
        cursor += UInt64(chunk.count)
      }

      recordStoreServe(bytes: servedCount)
      return .success(HTTPResponse(
        request: req,
        url: req.url,
        status: HTTPStatus(rawValue: 206) ?? .ok,
        headers: [
          "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(store.totalSize)",
          "Content-Length": "\(servedCount)"
        ],
        mediaType: nil,
        body: nil
      ))

    case let .fetchAndStore(range):
      os_log("LCPCACHE miss %{public}llu-%{public}llu %{public}d", log: lcpCacheLog, type: .default,
             range.lowerBound, range.upperBound, range.count)
      defer { releaseCacheSlot() }
      return await fetchAndStore(req: req, key: key, range: range, store: store, consume: consume)

    case let .fillGaps(requested, missing):
      os_log("LCPCACHE gapfill %{public}llu-%{public}llu %{public}d in %{public}d gap(s)",
             log: lcpCacheLog, type: .default,
             requested.lowerBound, requested.upperBound, requested.count, missing.count)
      defer { releaseCacheSlot() }
      guard let store else {
        // Decided with a store in hand, so this cannot happen; fetching the
        // window is the answer that is never wrong if it somehow does.
        return await fetchAndStore(req: req, key: key, range: requested, store: nil, consume: consume)
      }
      for gap in missing {
        var gapRequest = req
        gapRequest.setRange(gap)
        let gapBuffer = LockIsolated(Data())
        // The caller's `consume` is not passed down: it expects the bytes of
        // the window it asked for, in order, and a gap is a fragment of that
        // window. The assembled range is handed over once, below.
        let gapResult = await streamFromOrigin(request: gapRequest) { chunk, _ in
          gapBuffer.withValue { $0.append(chunk) }
          return .success(())
        }
        guard case let .success(gapResponse) = gapResult else {
          log(.warning, "partial archive cache: a gap fetch failed — reading the window through")
          return await fetchAndStore(
            req: req, key: key, range: requested, store: store, consume: consume
          )
        }
        let gapBody = gapBuffer.value
        guard case let .store(offset) = Self.admitResponse(
          status: gapResponse.status.rawValue,
          contentRange: gapResponse.valueForHeader("Content-Range"),
          requested: gap,
          bodyLength: gapBody.count
        ) else {
          log(.warning, "partial archive cache: a gap response was not admissible — reading the window through")
          return await fetchAndStore(
            req: req, key: key, range: requested, store: store, consume: consume
          )
        }
        // Queued like the whole-window write above. The `read` below is also a
        // `storeQueue` hop, and the queue is serial, so it runs after these.
        storeAsync { try? store.write(gapBody, at: offset) }
      }

      // Never serve what we cannot prove we hold: an unwritten extent reads
      // back as zeros of exactly the right length, and nothing downstream
      // would notice. If the window is not whole now, go to the origin.
      guard let data = await onStoreQueue({ try? store.read(requested) }),
            data.count == requested.count
      else {
        log(.warning, "partial archive cache: the window was still not whole after filling — reading it through")
        return await fetchAndStore(
          req: req, key: key, range: requested, store: store, consume: consume
        )
      }
      if case let .failure(error) = consume(data, 1.0) {
        return .failure(error)
      }
      return .success(Self.partialResponse(
        for: req, range: requested, served: data.count, totalSize: store.totalSize
      ))
    }
  }

  // MARK: - Fetching

  /// Fetches a whole range, hands it to the caller as it arrives, and keeps it.
  ///
  /// Shared by the whole-window fetch and by gap filling's fallbacks, so there is
  /// one admission and one write path rather than two that can drift apart.
  private func fetchAndStore(
    req: HTTPRequest,
    key: String,
    range: Range<UInt64>,
    store: ArchiveRangeStore?,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    let buffer = LockIsolated(Data())
    let result = await streamFromOrigin(request: req) { chunk, progress in
      buffer.withValue { $0.append(chunk) }
      return consume(chunk, progress)
    }
    guard case let .success(response) = result else { return result }

    let contentRange = response.valueForHeader("Content-Range")
    let body = buffer.value
    // The store may not exist yet: this response is what reveals the length.
    let target = store ?? openStore(
      for: key,
      totalSizeFrom: contentRange.flatMap { Self.parseContentRange($0)?.totalSize }
    )
    guard let target else { return .success(response) }

    switch Self.admitResponse(
      status: response.status.rawValue,
      contentRange: contentRange,
      requested: range,
      bodyLength: body.count
    ) {
    case let .store(offset):
      // A write that runs out of space commits the prefix that reached disk
      // and records exactly that, so a later read refetches only the tail.
      //
      // Queued, not awaited: the caller is Readium reading the chapter these
      // bytes are for, and the commit ends in two `F_FULLFSYNC`s against a
      // sparse multi-gigabyte archive — the slowest step on the path, for a
      // result nothing in this response needs. `storeQueue` is serial, so a
      // later `missingRanges` or `read` still observes this write.
      storeAsync { try? target.write(body, at: offset) }
    case let .reject(reason):
      log(.warning, "partial archive cache: not storing this response (\(reason))")
    }
    return .success(response)
  }

  /// The 206 this client synthesises when it answered from the store.
  ///
  /// Readium reads `Content-Range` to learn the archive's length, so a served
  /// response has to state it the same way the origin would.
  private static func partialResponse(
    for req: HTTPRequest,
    range: Range<UInt64>,
    served: Int,
    totalSize: UInt64
  ) -> HTTPResponse {
    HTTPResponse(
      request: req,
      url: req.url,
      status: HTTPStatus(rawValue: 206) ?? .ok,
      headers: [
        "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalSize)",
        "Content-Length": "\(served)"
      ],
      mediaType: nil,
      body: nil
    )
  }


  // MARK: - Coverage

  /// What a read of a track's opening bytes actually moves off the origin.
  ///
  /// Every buffer in the chain fetches
  /// `lowerBound ..< max(upperBound, lowerBound + bufferSize)`, so the floor is
  /// `max(per-track window, Readium's archive buffer)` and both are 6 MB. A
  /// caller asking "is this track's start already cached" has to ask about a
  /// whole fill, because a smaller question answers about a read nobody makes.
  /// Public because the app predicts a slow chapter start from it and cannot
  /// see the loader's own copy of the number.
  public static let archiveFillSize: UInt64 = 6 * 1024 * 1024

  /// Whether every byte of `range` for the archive at `url` is already on
  /// disk, so reading it costs no origin traffic.
  ///
  /// Answers only from a store that is already open: this is asked on a UI
  /// path, and opening one here would turn a question into work. A closed
  /// store reads as "not cached", which predicts a slow read — the safe
  /// direction, since the alternative is telling the patron a cold chapter
  /// will be quick.
  public func rangeIsFullyCached(_ range: Range<UInt64>, forArchiveAt url: HTTPURL) -> Bool {
    guard !range.isEmpty else { return true }
    lock.lock()
    let store = stores[url.string]
    lock.unlock()
    guard let store else { return false }
    return store.missingRanges(in: range).isEmpty
  }

  // MARK: - Store lifecycle

  /// The store for this archive, opening it when a length is supplied.
  ///
  /// Called without a length on the way in, which only looks up what is
  /// already open, and with one after a response has reported it.
  private func openStore(for key: String, totalSizeFrom totalSize: UInt64? = nil) -> ArchiveRangeStore? {
    lock.lock()
    if let existing = stores[key] {
      lock.unlock()
      return existing
    }
    if let notBefore = storeRetryNotBefore[key], monotonicNow() < notBefore {
      lock.unlock()
      return nil
    }
    lock.unlock()

    // A length of zero names no bytes; asking the factory for it would be
    // asking it to create an empty store.
    if let totalSize, totalSize == 0 { return nil }

    do {
      guard let url = HTTPURL(string: key) else { throw StoreKeyError.notAnHTTPURL(key) }
      // Declining is not failing: with no length yet the factory answers
      // only for an archive already on disk, and most are not.
      guard let opened = try storeFactory(url, totalSize) else { return nil }
      lock.lock()
      let winner = stores[key] ?? opened
      stores[key] = winner
      storeRetryNotBefore[key] = nil
      lock.unlock()
      return winner
    } catch {
      // One store per archive per process holds an exclusive lock, and a
      // factory that cannot give us one must not take the patron's read down
      // with it: the request falls back to the origin and the book plays.
      //
      // Held off for an interval rather than refused outright: the condition
      // behind the failure is usually temporary, and an archive refused for
      // the whole process pays a full origin refetch for every window read
      // after it.
      log(.warning, "partial archive cache: could not open a store (\(error)) — reading through")
      lock.lock()
      storeRetryNotBefore[key] = monotonicNow() + storeRetryInterval
      lock.unlock()
      return nil
    }
  }

  private enum StoreKeyError: Error { case notAnHTTPURL(String) }

  /// Internal rather than private so the bound can be driven directly in a
  /// test: it is stateful, so nothing pure observes whether the counter
  /// actually moves.
  func reserveCacheSlot() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard cachedRequestsInFlight < maxConcurrentCachedRequests else { return false }
    cachedRequestsInFlight += 1
    return true
  }

  /// See `reserveCacheSlot()` for why this is not private.
  func releaseCacheSlot() {
    lock.lock()
    defer { lock.unlock() }
    if cachedRequestsInFlight > 0 { cachedRequestsInFlight -= 1 }
  }

  /// Every store call is synchronous blocking file I/O, so it is hopped onto
  /// the store queue rather than run on the cooperative thread this `async`
  /// method is using.
  private func onStoreQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      storeQueue.async { continuation.resume(returning: body()) }
    }
  }

  /// Runs a store call without waiting for it.
  ///
  /// For writes only, and only because nothing in the response depends on the
  /// result. `storeQueue` is serial, so ordering against every later store call
  /// is preserved; what is given up is only the caller's knowledge of when the
  /// commit finished, which no caller uses.
  private func storeAsync(_ body: @escaping @Sendable () -> Void) {
    storeQueue.async(execute: body)
  }
}
