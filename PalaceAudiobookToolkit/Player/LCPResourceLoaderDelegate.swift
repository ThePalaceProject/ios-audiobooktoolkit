import Foundation
import AVFoundation
import ReadiumShared
import UniformTypeIdentifiers

final class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    
    weak var provider: StreamingResourceProvider?
    private let httpRangeRetriever = HTTPRangeRetriever()
    private var fullTrackCache = [String: Data]()
    
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
        
        if provider?.getPublication() == nil {
            Task { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let pub = self.provider?.getPublication() {
                        await self.serve(loadingRequest: loadingRequest, with: pub)
                        return
                    }
                }
                loadingRequest.finishLoading(with: NSError(
                    domain: "LCPResourceLoader",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Publication not available for streaming"]
                ))
            }
            return true
        }
        
        if let pub = provider?.getPublication() {
            Task { [weak self] in
                await self?.serve(loadingRequest: loadingRequest, with: pub)
            }
            return true
        }
        
        loadingRequest.finishLoading(with: NSError(
            domain: "LCPResourceLoader",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Unknown streaming error"]
        ))
        return false
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        
    }
}

// MARK: - Helpers
private extension LCPResourceLoaderDelegate {
    @MainActor
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
        } else {
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
            
            Task {
                if let res = resource,
                   let maybeLength = try? await res.estimatedLength().get(),
                   let totalLength = maybeLength {
                    info.contentLength = Int64(totalLength)
                    ATLog(.debug, "🎯 [LCPResourceLoader] Set content length: \(totalLength) bytes for track: \(finalHref)")
                } else {
                    ATLog(.error, "🎯 [LCPResourceLoader] ❌ Failed to get content length for track: \(finalHref)")
                }
            }
        }
        
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }
        
        let start = max(0, Int(dataRequest.requestedOffset))
        let count = Int(dataRequest.requestedLength)
        let endExcl = start + count
        
        Task {
            if let res = resource {
                do {
                    let maxChunkSize = 512 * 1024
                    let actualCount = min(count, maxChunkSize)
                    let actualEndExcl = start + actualCount
                    let requestedRange: Range<UInt64> = UInt64(start)..<UInt64(actualEndExcl)
                    
                    let rawData = try await res.read(range: requestedRange).get()
                    let hexPrefix = rawData.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
                    let isValidAudio = rawData.starts(with: [0xFF, 0xFB]) || rawData.starts(with: [0xFF, 0xFA]) || rawData.starts(with: [0x49, 0x44, 0x33])
                    
                    let data = rawData
                    
                    if !data.isEmpty {
                        let hexPrefix = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
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
