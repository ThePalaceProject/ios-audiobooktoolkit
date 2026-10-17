//
//  PartialArchiveCachingHTTPClient.swift
//  PalaceAudiobookToolkit
//
//  Keeps the bytes Readium reads of a remote LCP archive instead of
//  discarding them, so a read-ahead becomes download progress (PP-5367).
//

import Foundation
import ReadiumShared

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

/// Opens the store for an archive once its true length is known.
///
/// Length comes from the first response's `Content-Range`, so the store cannot
/// be opened before one request has come back; see `stream`. The factory also
/// owns the policy for an archive whose recorded length no longer matches —
/// delete and start over — because that is a data decision, not this client's.
public typealias ArchiveRangeStoreFactory = (HTTPURL, UInt64) throws -> ArchiveRangeStore

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

  private let upstream: HTTPClient
  private let storeFactory: ArchiveRangeStoreFactory
  private let maxCacheableRangeLength: Int
  private let maxConcurrentCachedRequests: Int

  /// Store calls are synchronous blocking file I/O. Reached from `stream`,
  /// which is `async`, so they are hopped onto this queue rather than run
  /// inline: blocking a cooperative thread would stall unrelated work.
  private let storeQueue = DispatchQueue(
    label: "com.palace.partial-archive-store",
    qos: .userInitiated
  )

  private let lock = NSLock()
  private var stores: [String: ArchiveRangeStore] = [:]
  private var storesRefused: Set<String> = []
  private var cachedRequestsInFlight = 0

  public init(
    upstream: HTTPClient,
    storeFactory: @escaping ArchiveRangeStoreFactory,
    maxCacheableRangeLength: Int = PartialArchiveCachingHTTPClient.defaultMaxCacheableRangeLength,
    maxConcurrentCachedRequests: Int = PartialArchiveCachingHTTPClient
      .defaultMaxConcurrentCachedRequests
  ) {
    self.upstream = upstream
    self.storeFactory = storeFactory
    self.maxCacheableRangeLength = maxCacheableRangeLength
    self.maxConcurrentCachedRequests = maxConcurrentCachedRequests
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
    hasCacheSlot: Bool
  ) -> CacheDecision {
    guard isRangedGET, let requested, !requested.isEmpty else {
      return .passThrough(reason: "not a ranged GET")
    }
    // Serving costs no buffer, so neither cap applies to it.
    if let missing, missing.isEmpty {
      return .serveFromStore(requested)
    }
    guard requested.count <= maxCacheableRangeLength else {
      return .passThrough(reason: "range is larger than the memory cap for validation")
    }
    guard hasCacheSlot else {
      return .passThrough(reason: "too many cacheable requests already in flight")
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

  // MARK: - HTTPClient

  public func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return await upstream.stream(request: request, consume: consume)
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
      hasCacheSlot: reserved
    )
    if case .fetchAndStore = decision {} else if reserved {
      releaseCacheSlot()
    }

    switch decision {
    case let .passThrough(reason):
      log(.debug, "partial archive cache: passing through (\(reason))")
      return await upstream.stream(request: req, consume: consume)

    case let .serveFromStore(range):
      guard let store,
            let data = await onStoreQueue({ try? store.read(range) }),
            data.count == range.count
      else {
        // The record and the file disagree. Never serve what we cannot prove
        // we hold — a hole reads back as zeros of the right length and nothing
        // downstream would notice. Go to the origin instead.
        log(.warning, "partial archive cache: a range recorded present could not be read — refetching")
        return await upstream.stream(request: req, consume: consume)
      }
      if case let .failure(error) = consume(data, 1.0) {
        return .failure(error)
      }
      return .success(HTTPResponse(
        request: req,
        url: req.url,
        status: HTTPStatus(rawValue: 206) ?? .ok,
        headers: [
          "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(store.totalSize)",
          "Content-Length": "\(data.count)"
        ],
        mediaType: nil,
        body: nil
      ))

    case let .fetchAndStore(range):
      defer { releaseCacheSlot() }
      let buffer = LockIsolated(Data())
      let result = await upstream.stream(request: req) { chunk, progress in
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
        await onStoreQueue { try? target.write(body, at: offset) }
      case let .reject(reason):
        log(.warning, "partial archive cache: not storing this response (\(reason))")
      }
      return .success(response)
    }
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
    guard let totalSize, totalSize > 0, !storesRefused.contains(key) else {
      lock.unlock()
      return nil
    }
    lock.unlock()

    do {
      guard let url = HTTPURL(string: key) else { throw StoreKeyError.notAnHTTPURL(key) }
      let opened = try storeFactory(url, totalSize)
      lock.lock()
      let winner = stores[key] ?? opened
      stores[key] = winner
      lock.unlock()
      return winner
    } catch {
      // One store per archive per process holds an exclusive lock, and a
      // factory that cannot give us one must not take the patron's read down
      // with it: the request falls back to the origin and the book plays.
      log(.warning, "partial archive cache: could not open a store (\(error)) — reading through")
      lock.lock()
      storesRefused.insert(key)
      lock.unlock()
      return nil
    }
  }

  private enum StoreKeyError: Error { case notAnHTTPURL(String) }

  private func reserveCacheSlot() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard cachedRequestsInFlight < maxConcurrentCachedRequests else { return false }
    cachedRequestsInFlight += 1
    return true
  }

  private func releaseCacheSlot() {
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
}
