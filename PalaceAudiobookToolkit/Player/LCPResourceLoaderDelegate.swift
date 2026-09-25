import AVFoundation
import Foundation
import ReadiumShared
import UniformTypeIdentifiers

// MARK: - LCPResourceLoaderDelegate

final class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
  weak var provider: StreamingResourceProvider?
  private var fullTrackCache = [String: Data]()
  private let maxConcurrentRequests = 8
  /// How long a data transfer may go without delivering a byte before the
  /// request is failed with `LCPResourceLoaderError.transferStalled`.
  ///
  /// This bounds INACTIVITY in the data phase only. It deliberately does not
  /// apply while a request waits on a track's length (see `serve`), and it sits
  /// above the 60 s idle timeout of the `URLSessionConfiguration.default`
  /// sessions Readium's `DefaultHTTPClient` uses, so a network stall surfaces as
  /// the transport's own error, with its real cause, before this fires.
  private let stallTimeout: TimeInterval
  private let inflightQueue = DispatchQueue(label: "com.palace.lcp-streaming.inflight", attributes: .concurrent)
  private var inflightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private let concurrencySemaphore = DispatchSemaphore(value: 8)
  /// Decrypted length per track href, for the life of the publication.
  ///
  /// Every loading request resolves a new Readium resource, and a CBC LCP
  /// resource learns its length by fetching the last encrypted blocks of the
  /// track. Without this, that tail fetch ran once per loading request — at
  /// every track start, and again for each to-end read. A lookup that fails is
  /// dropped so the next request asks again.
  private let lengths = LockIsolated<[String: Task<UInt64?, Never>]>([:])

  init(provider: StreamingResourceProvider? = nil, stallTimeout: TimeInterval = 90) {
    self.provider = provider
    self.stallTimeout = stallTimeout
    super.init()
  }

  /// Stops every request this loader is serving without finishing it. For
  /// teardown only: a request AVFoundation is still waiting on stays unanswered.
  func cancelAllRequests() {
    inflightQueue.sync {
      inflightTasks.values.forEach { $0.cancel() }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks.removeAll()
    }
  }

  func clearCaches() {
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.fullTrackCache.removeAll()
    }
    lengths.value = [:]
  }

  /// The object that owns the in-flight requests and caches cancels them.
  /// Previously only `LCPStreamingPlayer.deinit` called `shutdown()`, and that
  /// cross-object reach from a deinit is what the isolation made illegal.
  deinit {
    inflightTasks.values.forEach { $0.cancel() }
  }

  func shutdown() {
    cancelAllRequests()
    clearCaches()
    provider = nil
  }

  func resourceLoader(
    _: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    shouldWait(for: loadingRequest)
  }

  func resourceLoader(
    _: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    didCancel(loadingRequest)
  }

  func shouldWait(for loadingRequest: LCPStreamingLoadingRequest) -> Bool {
    guard let url = loadingRequest.requestURL else {
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Missing URL"]
      ))
      return false
    }

    let isValidScheme = (url.scheme == "fake" && url.host == "lcp-streaming") ||
      (url.scheme == "readium-lcp")

    guard isValidScheme else {
      ATLog(.error, "🎵 ResourceLoader: Invalid URL scheme: \(url.absoluteString)")
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid URL scheme"]
      ))
      return false
    }

    // Wait briefly for the publication if not yet available to avoid immediate failure
    var publication = provider?.getPublication()
    if publication == nil {
      let start = CFAbsoluteTimeGetCurrent()
      while publication == nil && (CFAbsoluteTimeGetCurrent() - start) < 0.8 {
        Thread.sleep(forTimeInterval: 0.02)
        publication = provider?.getPublication()
      }
    }
    guard let publication else {
      ATLog(.debug, "🎵 ResourceLoader: Publication not available after brief wait")
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Publication not available for streaming"]
      ))
      return false
    }

    startServing(loadingRequest: loadingRequest, with: publication)
    return true
  }

  /// AVFoundation no longer needs this request. Its task — length lookup and
  /// byte transfer alike — stops, and the request is left unfinished, as the
  /// cancellation contract requires.
  func didCancel(_ loadingRequest: LCPStreamingLoadingRequest) {
    let id = ObjectIdentifier(loadingRequest)
    inflightQueue.sync {
      inflightTasks[id]?.cancel()
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks.removeValue(forKey: id)
    }
  }
}

// MARK: - Loading-request seam

/// The parts of `AVAssetResourceLoadingRequest` the loader uses.
///
/// AVFoundation offers no way to construct a loading request outside a real
/// asset load, so the serving logic is written against this protocol and the
/// tests drive it with a recording fake. `AVAssetResourceLoadingRequest` is the
/// only production conformer.
protocol LCPStreamingLoadingRequest: AnyObject {
  var requestURL: URL? { get }
  /// True when AVFoundation asked for the content type and length.
  var needsContentInformation: Bool { get }
  /// The byte range AVFoundation asked for, or nil for a content-information-only request.
  var requestedRange: LCPRequestedRange? { get }
  func provideContentInformation(contentType: String, contentLength: Int64?)
  func respond(with data: Data)
  func finishLoading()
  func finishLoading(with error: Error?)
}

struct LCPRequestedRange: Equatable {
  let offset: Int64
  let length: Int
  let toEnd: Bool
}

extension AVAssetResourceLoadingRequest: LCPStreamingLoadingRequest {
  var requestURL: URL? { request.url }

  var needsContentInformation: Bool { contentInformationRequest != nil }

  var requestedRange: LCPRequestedRange? {
    dataRequest.map {
      LCPRequestedRange(
        offset: $0.requestedOffset,
        length: $0.requestedLength,
        toEnd: $0.requestsAllDataToEndOfResource
      )
    }
  }

  func provideContentInformation(contentType: String, contentLength: Int64?) {
    guard let info = contentInformationRequest else { return }
    info.contentType = contentType
    info.isByteRangeAccessSupported = true
    if let contentLength {
      info.contentLength = contentLength
    }
  }

  func respond(with data: Data) {
    dataRequest?.respond(with: data)
  }
}

// MARK: - Helpers

private extension LCPResourceLoaderDelegate {
  func startServing(loadingRequest: LCPStreamingLoadingRequest, with publication: Publication) {
    let id = ObjectIdentifier(loadingRequest)
    // The slot holds the semaphore itself, not the loader, so it can still be
    // signalled after the last reference to the loader goes away. A semaphore
    // disposed below its initial value traps in libdispatch.
    let slot = RequestSlot(concurrencySemaphore)
    slot.acquire()
    let serveTask = Task { [weak self, weak loadingRequest] in
      defer { slot.release() }
      guard let self, let loadingRequest else {
        return
      }
      await serve(loadingRequest: loadingRequest, with: publication, slot: slot)
      inflightQueue.async(flags: .barrier) { [weak self] in
        self?.inflightTasks.removeValue(forKey: id)
      }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks[id] = serveTask
    }
  }

  func serve(loadingRequest: LCPStreamingLoadingRequest, with pub: Publication, slot: RequestSlot) async {
    let request = FinishOnce(loadingRequest)
    guard let url = loadingRequest.requestURL else {
      request.fail(NSError(
        domain: "LCPResourceLoader", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing URL"]
      ))
      return
    }

    var trackIndex = 0
    var href = ""

    if url.scheme == "readium-lcp" {
      let host = url.host ?? ""
      let pathComponents = url.pathComponents.filter { $0 != "/" }

      if host.hasPrefix("track"),
         let indexStr = String(host.dropFirst(5)).components(separatedBy: CharacterSet.decimalDigits.inverted).first,
         let index = Int(indexStr)
      {
        trackIndex = index
        href = pathComponents.first ?? ""
        ATLog(.debug, "Using fallback track path: \(href)")
      }
    } else if url.scheme == "fake" && url.host == "lcp-streaming" {
      let comps = url.pathComponents
      trackIndex = (comps.count >= 3 && comps[1] == "track") ? Int(comps[2]) ?? 0 : 0
      href = url.lastPathComponent
    }

    var link: Link?

    if trackIndex < pub.readingOrder.count {
      link = pub.readingOrder[trackIndex]
      ATLog(.debug, "Found reading order item for track: \(href)")
    } else {
      link = pub.readingOrder.first { $0.href.contains(href) }
    }

    guard let validLink = link else {
      request.fail(NSError(
        domain: "LCPResourceLoader",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Track not found in reading order"]
      ))
      return
    }

    let finalHref = validLink.href.components(separatedBy: "#").first ?? validLink.href
    let resource = Self.resource(for: pub, href: finalHref)

    if resource is FailureResource {
      request.fail(NSError(
        domain: "LCPResourceLoader",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "FailureResource for href: \(finalHref)"]
      ))
      return
    }

    // Content-information phase. No timer runs here: the length lookup is a
    // network round trip for CBC resources, and a fixed timer at this point
    // failed requests whose lookup was still in progress (PP-5240). It ends
    // when the transport reports success or its own error, or when AVFoundation
    // cancels the request.
    if loadingRequest.needsContentInformation {
      let contentType = Self.utiIdentifier(forHref: finalHref, fallbackMime: validLink.mediaType?.string)
      var contentLength: Int64?
      if let resource {
        guard case let .some(length) = await length(ofTrack: finalHref, resource: resource) else {
          return // cancelled
        }
        contentLength = length.map { Int64($0) }
      }
      loadingRequest.provideContentInformation(contentType: contentType, contentLength: contentLength)
    }

    guard let range = loadingRequest.requestedRange else {
      request.succeed()
      return
    }

    guard let resource else {
      ATLog(.error, "🎵 ResourceLoader: No resource available for streaming")
      request.fail(NSError(
        domain: "LCPResourceLoader", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No resource available for streaming"]
      ))
      return
    }

    // The concurrency limit admits requests into the lookup phase; a transfer
    // gives its slot back so a long read cannot hold the resource-loader queue.
    slot.release()

    let start = max(0, Int(range.offset))
    var count = range.length
    if count == 0 && range.toEnd {
      guard case let .some(total) = await length(ofTrack: finalHref, resource: resource) else {
        return // cancelled
      }
      count = total.map { max(0, Int($0) - start) } ?? Int.max
    }

    await transfer(from: resource, start: start, count: count, to: request)
  }

  /// Reads `count` bytes from `start` into the request, failing it with
  /// `transferStalled` if `stallTimeout` passes with no bytes delivered. Stops without finishing
  /// when the serving task is cancelled.
  func transfer(from resource: Resource, start: Int, count: Int, to request: FinishOnce) async {
    let lastProgress = LockIsolated(Date())
    let stallTimeout = stallTimeout

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          let segmentSize = 128 * 1024
          var bytesRemaining = count
          var currentStart = start
          var totalBytesRead = 0
          while bytesRemaining > 0 {
            let thisCount = bytesRemaining == Int.max ? segmentSize : min(bytesRemaining, segmentSize)
            let endExcl = currentStart + thisCount
            // PP-4542: tolerate a length/size mismatch instead of failing the
            // AVPlayerItem. Readium 3.9.0's LCP resource can report a length
            // larger than ZIPFoundation will serve — extractRange throws
            // rangeOutOfBounds when a range's upperBound exceeds the ZIP entry's
            // uncompressedSize. AVPlayer's first-open TAIL probe (it reads the
            // last bytes for mp3 duration/metadata) then overshoots and the item
            // dead-ends ("Audiobook Unavailable"). CLAMP the read to the largest
            // readable prefix and finish SUCCESSFULLY, so AVPlayer gets the real
            // tail bytes and plays.
            let (data, reachedEOF) = try await LCPResourceLoaderDelegate.readClampedToAvailable(
              start: UInt64(currentStart),
              requestedEnd: UInt64(endExcl)
            ) { try await resource.read(range: $0).get() }
            if Task.isCancelled { return }
            if !data.isEmpty {
              request.respond(with: data)
              lastProgress.value = Date()
              totalBytesRead += data.count
              if bytesRemaining != Int.max {
                bytesRemaining -= data.count
              }
              currentStart += data.count
            }
            if reachedEOF || data.isEmpty {
              break
            }
          }
          ATLog(.debug, "🎵 ResourceLoader: Successfully loaded \(totalBytesRead) bytes (decrypted)")
          request.succeed()
        } catch {
          if Task.isCancelled { return }
          ATLog(.error, "🎵 ResourceLoader: ERROR loading data (after cold-load retries): \(error)")
          request.fail(error)
        }
      }

      group.addTask {
        while true {
          let idle = Date().timeIntervalSince(lastProgress.value)
          if idle >= stallTimeout {
            ATLog(.warn, "🎵 ResourceLoader: no bytes for \(Int(idle)) s — failing the request")
            request.fail(LCPResourceLoaderError.transferStalled)
            return
          }
          do {
            try await Task.sleep(nanoseconds: UInt64((stallTimeout - idle) * 1_000_000_000))
          } catch {
            return // cancelled
          }
        }
      }

      // Whichever ends first decides; the other is cancelled. A read that
      // ignores cancellation keeps this task alive, but the request has
      // already been answered and the slot released.
      await group.next()
      group.cancelAll()
    }
  }

  /// The track's decrypted length: `.some(length)` once known (`length` nil if
  /// the lookup failed), or `nil` if the calling task was cancelled first.
  func length(ofTrack href: String, resource: Resource) async -> UInt64?? {
    let lookup = lengths.withValue { cache -> Task<UInt64?, Never> in
      if let existing = cache[href] {
        return existing
      }
      let task = Task<UInt64?, Never> {
        if case let .success(length) = await resource.estimatedLength() {
          return length
        }
        return nil
      }
      cache[href] = task
      return task
    }
    guard let result = await Self.value(of: lookup) else {
      return nil
    }
    if result == nil {
      lengths.withValue { cache in
        if cache[href] == lookup {
          cache[href] = nil
        }
      }
    }
    return .some(result)
  }

  /// `task.value`, or nil as soon as the CALLING task is cancelled.
  ///
  /// Awaiting `Task.value` does not observe the waiter's cancellation, and
  /// Readium's CBC length lookup runs in an unstructured task of its own, so a
  /// cancelled request would otherwise stay parked — holding its concurrency
  /// slot — until a lookup it no longer wants finished.
  static func value<T: Sendable>(of task: Task<T, Never>) async -> T? {
    let gate = ResumeOnce<T?>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        gate.install(continuation)
        Task { gate.resume(with: await task.value) }
      }
    } onCancel: {
      gate.resume(with: nil)
    }
  }

  static func resource(for publication: Publication, href: String) -> Resource? {
    if let res = publication.get(Link(href: href)), type(of: res) != FailureResource.self {
      return res
    }
    if let res = publication.get(Link(href: "/" + href)), type(of: res) != FailureResource.self {
      return res
    }
    if let base = publication.linkWithRel(.self)?.href,
       let absolute = URL(string: href, relativeTo: URL(string: base)!)?.absoluteString
    {
      if let res = publication.get(Link(href: absolute)), type(of: res) != FailureResource.self {
        return res
      }
    }
    return nil
  }

  static func utiIdentifier(forHref href: String, fallbackMime: String?) -> String {
    let ext = URL(fileURLWithPath: href).pathExtension.lowercased()

    if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
      return type.identifier
    }

    switch ext {
    case "mp3":
      return "public.mp3"
    case "m4a":
      return "com.apple.m4a-audio"
    case "mp4":
      return "public.mpeg-4"
    default:
      break
    }

    if let mime = fallbackMime?.lowercased() {
      if mime.contains("mpeg") || mime.contains("mp3") {
        return "public.mp3"
      }
      if mime.contains("m4a") || mime.contains("mp4") {
        return "com.apple.m4a-audio"
      }
    }

    return "public.audio"
  }
}

// MARK: - Range clamp (PP-4542)

// Internal (not `private`) so the clamp logic is unit-testable via
// `@testable import` without standing up a real AVAsset + Readium Resource stack.
extension LCPResourceLoaderDelegate {
  /// Classifies a `Resource.read(range:)` error as a *range-out-of-bounds*
  /// failure. Readium 3.9.0 (PP-4340) / ReadiumZIPFoundation throws
  /// `Archive.ArchiveError.rangeOutOfBounds` when a requested range's upperBound
  /// exceeds the ZIP entry's `uncompressedSize` — i.e. the LCP resource reported
  /// a length larger than it can actually serve, so AVPlayer's tail probe
  /// overshoots. Matched on the error *description* so we don't couple to
  /// Readium's nested error-enum layout (which the 3.9.0 bump itself changed).
  static func isRangeOutOfBoundsError(_ error: Error) -> Bool {
    let desc = String(describing: error).lowercased()
    return desc.contains("rangeoutofbounds")
      || desc.contains("out of bounds")
      || desc.contains("out-of-bounds")
  }

  /// Reads `[start, requestedEnd)`, tolerating a length/size mismatch instead of
  /// failing. If the underlying resource throws `rangeOutOfBounds` (it reported a
  /// length larger than it can serve), this CLAMPS to the largest readable prefix
  /// via binary search and returns that, signalling EOF — rather than dead-ending
  /// the AVPlayerItem. This is the durable fix for the 3.2.0 first-open
  /// "Audiobook Unavailable" regression: AVPlayer's tail metadata probe overshoots
  /// the real decrypted size, and a hard failure there kills the whole item.
  ///
  /// Returns `(data, reachedEOF)`:
  ///   • a normal full read → `(data, data.count < requested)`,
  ///   • an overshoot clamped to the real end → `(clampedData, true)`,
  ///   • `start` already at/after EOF → `(empty, true)`.
  /// Non-bounds errors (decryption, cancellation, network) are re-thrown
  /// unchanged — never masked. Binary search only runs on the rare overshoot, so
  /// well-formed reads stay single-shot.
  static func readClampedToAvailable(
    start: UInt64,
    requestedEnd: UInt64,
    isOutOfBounds: (Error) -> Bool = LCPResourceLoaderDelegate.isRangeOutOfBoundsError,
    _ read: (Range<UInt64>) async throws -> Data
  ) async throws -> (data: Data, reachedEOF: Bool) {
    guard requestedEnd > start else { return (Data(), true) }
    do {
      let data = try await read(start..<requestedEnd)
      return (data, data.count < Int(requestedEnd - start))
    } catch {
      guard isOutOfBounds(error) else { throw error }
      // The real readable end is somewhere in [start, requestedEnd). Binary-search
      // the largest `end` for which read(start..<end) succeeds. Invariant:
      // read(start..<lo) is known-OK (lo==start ⇒ empty), read(start..<hi) failed.
      var lo = start
      var hi = requestedEnd
      while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2
        do {
          _ = try await read(start..<mid)
          lo = mid
        } catch {
          guard isOutOfBounds(error) else { throw error }
          hi = mid
        }
      }
      guard lo > start else {
        ATLog(.debug, "🎵 ResourceLoader: range start \(start) is past EOF — serving empty (clamped)")
        return (Data(), true)
      }
      let data = try await read(start..<lo)
      ATLog(.warn, "🎵 ResourceLoader: clamped overshooting range \(start)..<\(requestedEnd) to real EOF \(lo) (\(data.count) bytes) — LCP/ZIP length mismatch (PP-4542)")
      return (data, true)
    }
  }
}

// MARK: - Serving primitives

/// A failure the loader itself decides on, as opposed to one passed through
/// from Readium or the transport.
///
/// AVFoundation rebuilds a loader error from its code alone and drops the
/// domain: `-1001` comes back as `NSURLErrorDomain -1001 "The request timed
/// out"`, indistinguishable from a real network timeout. The stall bound used
/// that code until PP-5240, which is why the field reports could not tell the
/// loader's timer from the network. Codes here stay clear of the
/// `NSURLError` range (all negative) so they cannot be read as one.
enum LCPResourceLoaderError: Int, CustomNSError {
  /// A data transfer delivered no bytes for the loader's stall timeout.
  case transferStalled = 5240

  static var errorDomain: String { "LCPResourceLoader" }
  var errorCode: Int { rawValue }
  var errorUserInfo: [String: Any] {
    switch self {
    case .transferStalled:
      return [NSLocalizedDescriptionKey: "Streaming transfer delivered no data within the stall timeout"]
    }
  }
}

/// One admission slot on the loader's concurrency semaphore, released at most once.
final class RequestSlot: @unchecked Sendable {
  private let semaphore: DispatchSemaphore
  private let held = LockIsolated(false)

  init(_ semaphore: DispatchSemaphore) {
    self.semaphore = semaphore
  }

  func acquire() {
    semaphore.wait()
    held.value = true
  }

  func release() {
    let wasHeld = held.withValue { held -> Bool in
      defer { held = false }
      return held
    }
    if wasHeld {
      semaphore.signal()
    }
  }
}

/// Answers a loading request at most once. The transfer and its stall timer
/// race to finish the same request; only the first answer reaches AVFoundation.
final class FinishOnce: @unchecked Sendable {
  private let request: LCPStreamingLoadingRequest
  private let finished = LockIsolated(false)

  init(_ request: LCPStreamingLoadingRequest) {
    self.request = request
  }

  func respond(with data: Data) {
    guard !finished.value else { return }
    request.respond(with: data)
  }

  func succeed() {
    if claim() { request.finishLoading() }
  }

  func fail(_ error: Error) {
    if claim() { request.finishLoading(with: error) }
  }

  private func claim() -> Bool {
    finished.withValue { finished -> Bool in
      defer { finished = true }
      return !finished
    }
  }
}

/// Resumes a continuation exactly once, whether the value or the cancellation
/// arrives first, and whether either arrives before the continuation exists.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
  private enum State {
    case idle
    case waiting(CheckedContinuation<T, Never>)
    case early(T)
    case done
  }

  private let lock = NSLock()
  private var state = State.idle

  func install(_ continuation: CheckedContinuation<T, Never>) {
    let early: T? = lock.withLock {
      switch state {
      case let .early(value):
        state = .done
        return value
      case .idle:
        state = .waiting(continuation)
        return nil
      case .waiting, .done:
        return nil
      }
    }
    if let early {
      continuation.resume(returning: early)
    }
  }

  func resume(with value: T) {
    let waiting: CheckedContinuation<T, Never>? = lock.withLock {
      switch state {
      case .idle:
        state = .early(value)
        return nil
      case let .waiting(continuation):
        state = .done
        return continuation
      case .early, .done:
        return nil
      }
    }
    waiting?.resume(returning: value)
  }
}
