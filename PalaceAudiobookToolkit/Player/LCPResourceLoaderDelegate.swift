import AVFoundation
import Foundation
import ReadiumShared
import UniformTypeIdentifiers

// MARK: - LCPResourceLoaderDelegate

final class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
  weak var provider: StreamingResourceProvider?
  private let httpRangeRetriever = HTTPRangeRetriever()
  private var fullTrackCache = [String: Data]()
  private let maxConcurrentRequests = 8
  private let requestTimeoutSeconds: TimeInterval = 30
  private let inflightQueue = DispatchQueue(label: "com.palace.lcp-streaming.inflight", attributes: .concurrent)
  private var inflightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var timeoutGuards: [ObjectIdentifier: Task<Void, Never>] = [:]
  private let concurrencySemaphore = DispatchSemaphore(value: 8)

  init(provider: StreamingResourceProvider? = nil) {
    self.provider = provider
    super.init()
  }

  func cancelAllRequests() {
    inflightQueue.sync {
      inflightTasks.values.forEach { $0.cancel() }
      timeoutGuards.values.forEach { $0.cancel() }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks.removeAll()
      self?.timeoutGuards.removeAll()
    }
  }

  func clearCaches() {
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.fullTrackCache.removeAll()
    }
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
    guard let url = loadingRequest.request.url else {
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

  func resourceLoader(
    _: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let id = ObjectIdentifier(loadingRequest)
    inflightQueue.sync {
      if let task = inflightTasks[id] {
        task.cancel()
      }
      if let guardTask = timeoutGuards[id] {
        guardTask.cancel()
      }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks.removeValue(forKey: id)
      self?.timeoutGuards.removeValue(forKey: id)
    }
  }
}

// MARK: - Helpers

private extension LCPResourceLoaderDelegate {
  func startServing(loadingRequest: AVAssetResourceLoadingRequest, with publication: Publication) {
    let id = ObjectIdentifier(loadingRequest)
    // Concurrency limiting
    concurrencySemaphore.wait()
    let serveTask = Task { [weak self, weak loadingRequest] in
      defer { self?.concurrencySemaphore.signal() }
      guard let self, let loadingRequest else {
        return
      }
      await serve(loadingRequest: loadingRequest, with: publication)
      inflightQueue.async(flags: .barrier) { [weak self] in
        self?.inflightTasks.removeValue(forKey: id)
        self?.timeoutGuards[id]?.cancel()
        self?.timeoutGuards.removeValue(forKey: id)
      }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks[id] = serveTask
    }
    // Timeout guard
    let guardTask = Task { [weak self, weak loadingRequest] in
      do {
        try await Task.sleep(nanoseconds: UInt64((self?.requestTimeoutSeconds ?? 30) * 1_000_000_000))
      } catch { return }
      guard let self, let loadingRequest else {
        return
      }
      var stillInflight = false
      inflightQueue.sync {
        stillInflight = self.inflightTasks[id] != nil
      }
      if stillInflight {
        inflightQueue.sync {
          self.inflightTasks[id]?.cancel()
        }
        loadingRequest.finishLoading(with: NSError(
          domain: "LCPResourceLoader",
          code: -1001,
          userInfo: [NSLocalizedDescriptionKey: "Streaming request timed out"]
        ))
        inflightQueue.async(flags: .barrier) { [weak self] in
          self?.inflightTasks.removeValue(forKey: id)
          self?.timeoutGuards.removeValue(forKey: id)
        }
      }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.timeoutGuards[id] = guardTask
    }
  }

  func serve(loadingRequest: AVAssetResourceLoadingRequest, with pub: Publication) async {
    guard let url = loadingRequest.request.url else {
      loadingRequest.finishLoading(with: NSError(
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
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Track not found in reading order"]
      ))
      return
    }

    let finalHref = validLink.href.components(separatedBy: "#").first ?? validLink.href
    let resource = Self.resource(for: pub, href: finalHref)

    if resource is FailureResource {
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "FailureResource for href: \(finalHref)"]
      ))
      return
    }

    if let info = loadingRequest.contentInformationRequest {
      let contentType = Self.utiIdentifier(forHref: finalHref, fallbackMime: validLink.mediaType?.string)
      info.contentType = contentType
      info.isByteRangeAccessSupported = true
      if let res = resource, let maybeLength = try? await res.estimatedLength().get(), let totalLength = maybeLength {
        info.contentLength = Int64(totalLength)
      }
    }

    guard let dataRequest = loadingRequest.dataRequest else {
      loadingRequest.finishLoading()
      return
    }

    let start = max(0, Int(dataRequest.requestedOffset))
    var count = Int(dataRequest.requestedLength)

    Task.detached(priority: .userInitiated) {
      if let res = resource {
        do {
          let segmentSize = 128 * 1024
          var totalLength: Int?
          if let length = try? await res.estimatedLength().get(), let l = length {
            totalLength = Int(l)
          }
          ATLog(.debug, "🎵 ResourceLoader: Starting data request for range \(start)..., total length: \(totalLength?.description ?? "unknown")")
          
          if count == 0 && dataRequest.requestsAllDataToEndOfResource {
            if let total = totalLength {
              count = max(0, total - start)
            } else {
              count = Int.max
            }
          }
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
            ) { try await res.read(range: $0).get() }
            if !data.isEmpty {
              dataRequest.respond(with: data)
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
          loadingRequest.finishLoading()
        } catch {
          ATLog(.error, "🎵 ResourceLoader: ERROR loading data (after cold-load retries): \(error)")
          loadingRequest.finishLoading(with: error)
        }
        return
      }

      ATLog(.error, "🎵 ResourceLoader: No resource available for streaming")
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No resource available for streaming"]
      ))
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
