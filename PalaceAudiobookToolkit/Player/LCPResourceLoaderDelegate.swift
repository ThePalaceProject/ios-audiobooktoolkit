import Foundation
import AVFoundation
import ReadiumShared
import UniformTypeIdentifiers

final class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    
    weak var provider: StreamingResourceProvider?
    private let httpRangeRetriever = HTTPRangeRetriever()
    private var fullTrackCache = [String: Data]()
    private let maxConcurrentRequests = 4
    private let requestTimeoutSeconds: TimeInterval = 30
    private let inflightQueue = DispatchQueue(label: "com.palace.lcp-streaming.inflight", attributes: .concurrent)
    private var inflightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var timeoutGuards: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let concurrencySemaphore = DispatchSemaphore(value: 4)
    
    init(provider: StreamingResourceProvider? = nil) {
        self.provider = provider
        super.init()
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
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
        
        guard let publication = provider?.getPublication() else {
            ATLog(.debug, "🎵 ResourceLoader: Publication not available yet, failing fast")
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
        _ resourceLoader: AVAssetResourceLoader,
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
            guard let self, let loadingRequest else { return }
            await self.serve(loadingRequest: loadingRequest, with: publication)
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
            guard let self, let loadingRequest else { return }
            var stillInflight = false
            inflightQueue.sync {
                stillInflight = inflightTasks[id] != nil
            }
            if stillInflight {
                inflightQueue.sync {
                    inflightTasks[id]?.cancel()
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
        var href: String = ""
        
        if url.scheme == "readium-lcp" {
            let host = url.host ?? ""
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            
            if host.hasPrefix("track"), let indexStr = String(host.dropFirst(5)).components(separatedBy: CharacterSet.decimalDigits.inverted).first, let index = Int(indexStr) {
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
        let absoluteHTTPURL: HTTPURL? = {
            if let base = pub.linkWithRel(.self)?.href,
               let baseURL = URL(string: base),
               let resolved = URL(string: finalHref, relativeTo: baseURL),
               let http = HTTPURL(url: resolved) {
                return http
            }
            if let direct = URL(string: finalHref), let http = HTTPURL(url: direct) {
                return http
            }
            return nil
        }()
        
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
        let count = Int(dataRequest.requestedLength)
        let endExcl = start + count
        
        Task.detached(priority: .userInitiated) {
            if let res = resource {
                do {
                    let maxChunkSize = 512 * 1024
                    let actualCount = min(count, maxChunkSize)
                    let actualEndExcl = start + actualCount
                    let requestedRange: Range<UInt64> = UInt64(start)..<UInt64(actualEndExcl)
                    
                    let rawData = try await res.read(range: requestedRange).get()
                    let data = rawData
                    
                    if !data.isEmpty {
                        dataRequest.respond(with: data)
                    } else {
                        ATLog(.error, "🎯 [LCPResourceLoader] ❌ Empty data returned from Readium resource")
                    }
                    loadingRequest.finishLoading()
                } catch {

                    do {
                        let all = try await res.read(range: nil).get()
                        let upper = min(endExcl, all.count)
                        let lower = min(max(0, start), upper)
                        if lower < upper {
                            let slice = all.subdata(in: lower..<upper)
                            dataRequest.respond(with: slice)
                        }
                        loadingRequest.finishLoading()
                    } catch {
                        loadingRequest.finishLoading(with: error)
                    }
                }
                return
            }
            
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
        if let base = publication.linkWithRel(.self)?.href, let absolute = URL(string: href, relativeTo: URL(string: base)!)?.absoluteString {
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
            if mime.contains("mpeg") || mime.contains("mp3") { return "public.mp3" }
            if mime.contains("m4a") || mime.contains("mp4") { return "com.apple.m4a-audio" }
        }
        
        return "public.audio"
    }
}
