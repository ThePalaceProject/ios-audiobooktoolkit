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
            let range: Range<UInt64> = UInt64(currentStart)..<UInt64(endExcl)
            let data = try await res.read(range: range).get()
            if data.isEmpty {
              break
            }
            dataRequest.respond(with: data)
            totalBytesRead += data.count
            if bytesRemaining != Int.max {
              bytesRemaining -= data.count
            }
            currentStart += data.count
            if data.count < thisCount {
              break
            }
          }
          ATLog(.debug, "🎵 ResourceLoader: Successfully loaded \(totalBytesRead) bytes (decrypted)")
          loadingRequest.finishLoading()
        } catch {
          ATLog(.error, "🎵 ResourceLoader: ERROR loading data: \(error)")
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
