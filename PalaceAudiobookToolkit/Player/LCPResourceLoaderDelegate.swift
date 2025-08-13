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
        guard let url = loadingRequest.request.url,
              url.scheme == "fake",
              url.host == "lcp-streaming" else {
            ATLog(.error, "🎵 ResourceLoader: Invalid URL: \(loadingRequest.request.url?.absoluteString ?? "nil")")
            loadingRequest.finishLoading(with: NSError(
                domain: "LCPResourceLoader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]
            ))
            return false
        }
        
        ATLog(.debug, "🎵 ResourceLoader: Handling request for \(url.absoluteString)")

        // Publication may not be ready at asset creation; wait briefly if needed.
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

        let comps = url.pathComponents
        let index = (comps.count >= 3 && comps[1] == "track") ? Int(comps[2]) ?? 0 : 0
        guard (0..<pub.readingOrder.count).contains(index) else {
            loadingRequest.finishLoading(with: NSError(
                domain: "LCPResourceLoader",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Track index out of range"]
            ))
            return
        }

        let link = pub.readingOrder[index]
        let href = link.href.components(separatedBy: "#").first ?? link.href
        let resource = Self.resource(for: pub, href: href)
        let absoluteHTTPURL: HTTPURL? = {
            if let base = pub.linkWithRel(.self)?.href,
               let baseURL = URL(string: base),
               let resolved = URL(string: href, relativeTo: baseURL),
               let http = HTTPURL(url: resolved) {
                return http
            }
            if let direct = URL(string: href), let http = HTTPURL(url: direct) {
                return http
            }
            return nil
        }()

        if resource is FailureResource {
            loadingRequest.finishLoading(with: NSError(
                domain: "LCPResourceLoader",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "FailureResource for href: \(href)"]
            ))
            return
        }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.utiIdentifier(forHref: href, fallbackMime: link.mediaType?.string)
            info.isByteRangeAccessSupported = false

            Task {
                if let res = resource,
                   let maybeLength = try? await res.estimatedLength().get(),
                   let totalLength = maybeLength {
                    info.contentLength = Int64(totalLength)
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
                    let blob: Data
                    if let cached = self.fullTrackCache[href] {
                        blob = cached
                    } else {
                        // Fetch entire track once without Range probing; cache for subsequent slices
                        let all = try await res.read(range: nil).get()
                        self.fullTrackCache[href] = all
                        blob = all
                    }

                    let upper = min(endExcl, blob.count)
                    let lower = min(max(0, start), upper)
                    if lower < upper {
                        let slice = blob.subdata(in: lower..<upper)
                        dataRequest.respond(with: slice)
                    }
                    loadingRequest.finishLoading()
                } catch {
                    loadingRequest.finishLoading(with: error)
                }
                return
            }

            loadingRequest.finishLoading(with: NSError(
                domain: "LCPResourceLoader", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No decrypted resource available for streaming"]
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
