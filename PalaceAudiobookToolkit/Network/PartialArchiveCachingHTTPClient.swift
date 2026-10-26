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
///
/// `@unchecked Sendable` so a fill can be carried into a task that outlives the
/// request which started it (see `ArchiveFill`). It states what the type already
/// does: every mutable field is reached only under `lock` or on `storeQueue`,
/// and `upstream` and `storeFactory` are immutable. `upstream` is already
/// called from eight concurrent loader requests today, so the conformance
/// asserts nothing new about it.
public final class PartialArchiveCachingHTTPClient: HTTPClient, Loggable, @unchecked Sendable {

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

  /// Longest a detached fill may run before it is abandoned.
  ///
  /// A fill outlives the request that started it, so nothing else would ever
  /// return its cache slot. Chosen above the slowest serve measured on device
  /// (28.3s) and in the same range as URLSession's 60s request-inactivity
  /// default, so it bounds a trickle without cutting a legitimately slow window.
  public static let defaultMaxFillDuration: TimeInterval = 60

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
  private let maxFillDuration: TimeInterval
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
  /// Windows being fetched right now, per archive. Bounded by the same cache
  /// slot a fetch already had to reserve: a fill takes that slot over from the
  /// request that started it and releases it when it commits, so detaching the
  /// fetch does not widen the transient-memory bound the slot cap exists to set.
  private var fillsInFlight: [String: [ArchiveFill]] = [:]

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
    maxFillDuration: TimeInterval = PartialArchiveCachingHTTPClient
      .defaultMaxFillDuration,
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
    self.maxFillDuration = maxFillDuration
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
      guard let served = await serveWhollyFromStore(
        req: req, range: range, store: store, consume: consume
      ) else {
        return await streamFromOrigin(request: req, consume: consume)
      }
      return served

    case let .fetchAndStore(range):
      os_log("LCPCACHE miss %{public}llu-%{public}llu %{public}d", log: lcpCacheLog, type: .default,
             range.lowerBound, range.upperBound, range.count)
      // No `defer` here: the slot follows the fetch. `fetchAndStore` releases it
      // when it joins an existing fill, and hands it to the fill it starts
      // otherwise, so the bound still counts windows being buffered rather than
      // requests waiting on them.
      return await fetchAndStore(
        req: req, key: key, range: range, store: store, consume: consume, ownsCacheSlot: true
      )

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

  // MARK: - Serving

  /// Serves `range` from the store, or returns nil if the store cannot prove it
  /// holds all of it and nothing has been delivered yet.
  ///
  /// nil means "ask the origin, no byte has gone downstream". A returned
  /// `.failure` means bytes already reached the caller and the request cannot be
  /// retried, so the two are not interchangeable.
  private func serveWhollyFromStore(
    req: HTTPRequest,
    range: Range<UInt64>,
    store: ArchiveRangeStore,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse>? {
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
      return nil
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
          return nil
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
    consume: @escaping (Data, Double?) -> HTTPResult<Void>,
    ownsCacheSlot: Bool = false
  ) async -> HTTPResult<HTTPResponse> {
    // A window already crossing the link is not fetched twice. The joiner waits
    // for it and then reads its own sub-range out of the store, which is what
    // makes a burst of taps inside one window cost one fetch rather than one
    // each.
    if let existing = fill(forKey: key, covering: range) {
      // Released before waiting, not after: a joiner buffers nothing, so
      // holding a slot through someone else's fetch would starve the chapter.
      if ownsCacheSlot { releaseCacheSlot() }
      os_log("LCPCACHE join %{public}llu-%{public}llu into %{public}llu-%{public}llu",
             log: lcpCacheLog, type: .default,
             range.lowerBound, range.upperBound,
             existing.range.lowerBound, existing.range.upperBound)
      await existing.relay.waitForCommit()
      if let store,
         let served = await serveWhollyFromStore(
           req: req, range: range, store: store, consume: consume
         ) {
        return served
      }
      // The fill did not leave these bytes behind — it failed, or the store
      // refused them. Fetch them directly rather than reporting someone else's
      // outcome as this request's.
      return await fetchDirectly(req: req, key: key, range: range, store: store, consume: consume)
    }

    guard ownsCacheSlot else {
      // A gap fetch, whose caller holds the slot for the whole read. Detaching
      // it would let the read return while its own fills were still running,
      // and the gap path's next step reads the window it just filled.
      return await fetchDirectly(req: req, key: key, range: range, store: store, consume: consume)
    }

    let relay = FillRelay(originator: consume)
    // Registered before the fetch starts. The other order lets a fast fill
    // deregister an entry that has not been added yet, which strands it in the
    // table and sends every later overlapping request through a join that can
    // never be satisfied.
    register(ArchiveFill(range: range, relay: relay), forKey: key)
    // `Task`, not a child task: an unstructured task does not inherit
    // cancellation, which is the whole point — the fetch has to survive the
    // tap that cancelled the request so its bytes reach the store.
    Task { [self] in
      // Bounded, because the fill no longer dies with its caller. The session
      // this runs on is built with `DefaultHTTPClient()` and no resource
      // timeout, so `timeoutIntervalForResource` is URLSession's 7-day default:
      // a body that trickles rather than stalls would hold a cache slot for as
      // long as it liked, and before this change AVFoundation cancelling the
      // request was what returned that slot. The cap restores an upper bound,
      // well clear of the slowest serve measured on device (28.3s).
      let fetch = Task { [self] in
        await fetchDirectly(
          req: req, key: key, range: range, store: store,
          consume: { chunk, progress in relay.forward(chunk, progress) }
        )
      }
      let bound = Task {
        try? await Task.sleep(nanoseconds: UInt64(maxFillDuration * 1_000_000_000))
        guard !Task.isCancelled else { return }
        fetch.cancel()
      }
      let result = await fetch.value
      bound.cancel()
      // The originating request is the chapter the patron is waiting on, so it
      // is released as soon as the body is delivered.
      relay.finishBody(with: result)
      // `fetchDirectly` queues its commit rather than awaiting it, so the write
      // need not have run yet. A joiner released now would read the window
      // before it landed and fetch it again, losing the only thing joining
      // buys. `storeQueue` is serial, so this empty hop runs after that commit.
      _ = await onStoreQueue { true }
      deregisterFill(forKey: key, range: range)
      // The slot the request handed over, released once the buffer is gone.
      releaseCacheSlot()
      relay.finishCommit()
    }

    // Wait for the fill, but let go at once if this request is cancelled: the
    // fill keeps running, and the caller stops being handed chunks.
    await withTaskCancellationHandler {
      await relay.waitAsOriginator()
    } onCancel: {
      relay.detachOriginator()
    }

    if let result = relay.result { return result }
    // Cancelled: the fill is still running and will commit on its own. Report
    // this request as cancelled rather than inventing a response for it.
    return .failure(.cancelled)
  }

  /// The original fetch: stream the window, hand it to the caller as it
  /// arrives, and store it if the response proves where it belongs.
  private func fetchDirectly(
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

  // MARK: - Fills in flight

  /// An origin fetch of one window, outliving the request that started it.
  ///
  /// A skip burst cancels one range request per tap, every 0.2-0.3s, while a
  /// fill over a slow origin needs 2-5s for its first byte. A fetch tied to its
  /// caller's task is therefore cancelled before it can commit anything, the
  /// bytes it already paid for are dropped, and the next tap starts from
  /// nothing — so no tap ever produces audio (PP-5401). Registering the fill
  /// lets it finish and commit, and lets the next tap wait for it rather than
  /// open a second request for bytes already crossing the link.
  private struct ArchiveFill {
    let range: Range<UInt64>
    let relay: FillRelay
  }

  /// Carries one fill's chunks to whichever caller is still attached, and tells
  /// a caller when the fill is done.
  ///
  /// Two callers need different things from the same fetch. The request that
  /// started it wants the bytes streamed as they arrive, exactly as before. A
  /// request that joined wants the whole of its own sub-range, which it reads
  /// from the store once the fill lands. So the relay forwards only to the
  /// originator, and `wait()` is what a joiner — and the originator on
  /// cancellation — suspends on.
  final class FillRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var originator: ((Data, Double?) -> HTTPResult<Void>)?
    /// Joiners. Released only when the fill finishes, because a joiner that
    /// woke early would read the window before it was committed and fetch it
    /// again — the one thing joining exists to prevent.
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []
    /// The originating request. Released when the fill finishes OR when that
    /// request is cancelled, so a cancelled tap does not sit through the rest
    /// of a 5-28s fetch holding its caller open.
    private var originatorWaiter: CheckedContinuation<Void, Never>?
    private var isFinished = false
    private var isCommitted = false
    private var _result: HTTPResult<HTTPResponse>?

    /// The fill's own outcome, available once it has finished.
    var result: HTTPResult<HTTPResponse>? { lock.withLock { _result } }

    init(originator: @escaping (Data, Double?) -> HTTPResult<Void>) {
      self.originator = originator
    }

    /// Hands a chunk to the originating caller if it is still listening.
    ///
    /// A detached originator is not an error and must not fail the fill: the
    /// whole point is that the window keeps being fetched after the request
    /// that asked for it has gone.
    func forward(_ chunk: Data, _ progress: Double?) -> HTTPResult<Void> {
      let sink = lock.withLock { originator }
      guard let sink else { return .success(()) }
      return sink(chunk, progress)
    }

    /// Stops forwarding and releases the originating request only.
    func detachOriginator() {
      let resumed: CheckedContinuation<Void, Never>? = lock.withLock {
        originator = nil
        let pending = originatorWaiter
        originatorWaiter = nil
        return pending
      }
      resumed?.resume()
    }

    /// The body is delivered: records the outcome and releases the originating
    /// request, which must not wait for the commit.
    ///
    /// Two signals, not one, because the two waiters need opposite things. The
    /// originator is the chapter the patron is waiting on and the commit ends in
    /// two `F_FULLFSYNC`s against a sparse multi-gigabyte file, so making it
    /// wait would put the slowest step on the read path — which
    /// `PartialArchiveCacheWritePathTests` pins against. A joiner is about to
    /// read the window out of the store, so for it the commit is the whole
    /// point.
    func finishBody(with result: HTTPResult<HTTPResponse>) {
      let origin: CheckedContinuation<Void, Never>? = lock.withLock {
        guard !isFinished else { return nil }
        isFinished = true
        _result = result
        originator = nil
        let pending = originatorWaiter
        originatorWaiter = nil
        return pending
      }
      origin?.resume()
    }

    /// The window is on disk: releases the joiners, exactly once.
    func finishCommit() {
      let joined: [CheckedContinuation<Void, Never>] = lock.withLock {
        guard !isCommitted else { return [] }
        isCommitted = true
        let pending = joinWaiters
        joinWaiters = []
        return pending
      }
      joined.forEach { $0.resume() }
    }

    /// Suspends a joiner until the window has been committed to the store.
    func waitForCommit() async {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let committedAlready = lock.withLock {
          if isCommitted { return true }
          joinWaiters.append(continuation)
          return false
        }
        if committedAlready { continuation.resume() }
      }
    }

    /// Suspends the originating request until the fill finishes or it is
    /// detached. Only ever called once, by the request that created the relay.
    func waitAsOriginator() async {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let settled = lock.withLock {
          if isFinished || originator == nil { return true }
          originatorWaiter = continuation
          return false
        }
        if settled { continuation.resume() }
      }
    }
  }

  /// A registered fill whose window contains `range`, if there is one.
  ///
  /// Containment, not equality: Readium's windows are 6 MB and a skip tap moves
  /// the offset 330-460 kB, so consecutive taps land inside the window the
  /// previous tap is already fetching. Equality would match none of them.
  private func fill(forKey key: String, covering range: Range<UInt64>) -> ArchiveFill? {
    lock.lock()
    defer { lock.unlock() }
    return fillsInFlight[key]?.first {
      $0.range.lowerBound <= range.lowerBound && $0.range.upperBound >= range.upperBound
    }
  }

  private func register(_ fill: ArchiveFill, forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    fillsInFlight[key, default: []].append(fill)
  }

  private func deregisterFill(forKey key: String, range: Range<UInt64>) {
    lock.lock()
    defer { lock.unlock() }
    guard var fills = fillsInFlight[key] else { return }
    if let index = fills.firstIndex(where: { $0.range == range }) {
      fills.remove(at: index)
    }
    if fills.isEmpty { fillsInFlight.removeValue(forKey: key) } else { fillsInFlight[key] = fills }
  }

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
