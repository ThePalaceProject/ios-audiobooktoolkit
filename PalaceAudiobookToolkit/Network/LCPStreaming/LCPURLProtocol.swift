import Foundation
import AVFoundation
import ReadiumShared

#if LCP

/// URLProtocol subclass that intercepts HTTPS requests for LCP-protected content
/// and provides decrypted data while preserving HTTP Range streaming behavior
public class LCPURLProtocol: URLProtocol {
    
    // MARK: - Static Properties
    
    private static var registeredURLs: Set<String> = []
    private static var publicationCache: [String: Publication] = [:]
    private static var streamingBaseURLCache: [String: URL] = [:]
    
    // MARK: - Instance Properties
    
    private var task: URLSessionDataTask?
    private var publication: Publication?
    private var streamingBaseURL: URL?
    
    // MARK: - Public Registration
    
    /// Register an LCP-protected URL for interception
    public static func registerLCPURL(_ urlString: String, publication: Publication, streamingBaseURL: URL) {
        ATLog(.debug, "🔒 [LCPURLProtocol] Registering LCP URL: \(urlString)")
        registeredURLs.insert(urlString)
        publicationCache[urlString] = publication
        streamingBaseURLCache[urlString] = streamingBaseURL
    }
    
    /// Unregister an LCP-protected URL
    public static func unregisterLCPURL(_ urlString: String) {
        ATLog(.debug, "🔓 [LCPURLProtocol] Unregistering LCP URL: \(urlString)")
        registeredURLs.remove(urlString)
        publicationCache.removeValue(forKey: urlString)
        streamingBaseURLCache.removeValue(forKey: urlString)
    }
    
    /// Clear all registered URLs
    public static func clearAllRegistrations() {
        ATLog(.debug, "🔄 [LCPURLProtocol] Clearing all LCP URL registrations")
        registeredURLs.removeAll()
        publicationCache.removeAll()
        streamingBaseURLCache.removeAll()
    }
    
    // MARK: - URLProtocol Implementation
    
    public override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url,
              let scheme = url.scheme,
              scheme == "https" else {
            return false
        }
        
        let urlString = url.absoluteString
        let canHandle = registeredURLs.contains(urlString)
        
        if canHandle {
            ATLog(.debug, "🎯 [LCPURLProtocol] Can handle LCP request: \(urlString)")
        }
        
        return canHandle
    }
    
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    public override func startLoading() {
        guard let url = request.url else {
            ATLog(.error, "❌ [LCPURLProtocol] No URL in request")
            client?.urlProtocol(self, didFailWithError: NSError(domain: "LCPURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No URL in request"]))
            return
        }
        
        let urlString = url.absoluteString
        
        guard let publication = Self.publicationCache[urlString],
              let streamingBaseURL = Self.streamingBaseURLCache[urlString] else {
            ATLog(.error, "❌ [LCPURLProtocol] No publication cached for URL: \(urlString)")
            client?.urlProtocol(self, didFailWithError: NSError(domain: "LCPURLProtocol", code: -2, userInfo: [NSLocalizedDescriptionKey: "No publication cached"]))
            return
        }
        
        self.publication = publication
        self.streamingBaseURL = streamingBaseURL
        
        ATLog(.debug, "🚀 [LCPURLProtocol] Starting LCP request for: \(urlString)")
        
        // Extract the track filename from the URL
        let trackFilename = url.lastPathComponent
        
        // Find the corresponding resource in the publication
        guard let resource = publication.get(Link(href: trackFilename)) else {
            ATLog(.error, "❌ [LCPURLProtocol] Resource not found for: \(trackFilename)")
            client?.urlProtocol(self, didFailWithError: NSError(domain: "LCPURLProtocol", code: -3, userInfo: [NSLocalizedDescriptionKey: "Resource not found"]))
            return
        }
        
        // Handle HTTP Range requests
        handleRangeRequest(for: resource, trackFilename: trackFilename)
    }
    
    public override func stopLoading() {
        ATLog(.debug, "🛑 [LCPURLProtocol] Stopping loading")
        task?.cancel()
        task = nil
    }
    
    // MARK: - Private Methods
    
    private func handleRangeRequest(for resource: Resource, trackFilename: String) {
        // Parse Range header if present
        var range: Range<UInt64>?
        
        if let rangeHeader = request.value(forHTTPHeaderField: "Range") {
            ATLog(.debug, "📊 [LCPURLProtocol] Processing Range request: \(rangeHeader)")
            range = parseRangeHeader(rangeHeader)
        }
        
        // Get content length first
        Task {
            do {
                let contentLength = try await getContentLength(for: resource, trackFilename: trackFilename)
                
                await MainActor.run {
                    // Send response headers
                    let headers: [String: String]
                    let statusCode: Int
                    
                    if let range = range {
                        // Partial content response
                        let startByte = range.lowerBound
                        let endByte = range.upperBound - 1
                        
                        headers = [
                            "Content-Type": "audio/mpeg",
                            "Content-Length": "\(range.count)",
                            "Content-Range": "bytes \(startByte)-\(endByte)/\(contentLength)",
                            "Accept-Ranges": "bytes"
                        ]
                        statusCode = 206 // Partial Content
                        
                        ATLog(.debug, "📋 [LCPURLProtocol] Sending partial content response: \(startByte)-\(endByte)/\(contentLength)")
                    } else {
                        // Full content response
                        headers = [
                            "Content-Type": "audio/mpeg",
                            "Content-Length": "\(contentLength)",
                            "Accept-Ranges": "bytes"
                        ]
                        statusCode = 200 // OK
                        
                        ATLog(.debug, "📋 [LCPURLProtocol] Sending full content response: \(contentLength) bytes")
                    }
                    
                    let response = HTTPURLResponse(
                        url: self.request.url!,
                        statusCode: statusCode,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )!
                    
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    
                    // Now read and send the data
                    self.sendData(for: resource, range: range, trackFilename: trackFilename)
                }
            } catch {
                await MainActor.run {
                    ATLog(.error, "❌ [LCPURLProtocol] Failed to get content length: \(error)")
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
    }
    
    private func sendData(for resource: Resource, range: Range<UInt64>?, trackFilename: String) {
        Task {
            do {
                let dataRange = range ?? (0..<UInt64.max)
                
                ATLog(.debug, "📥 [LCPURLProtocol] Reading data range: \(dataRange.lowerBound)-\(dataRange.upperBound) for \(trackFilename)")
                
                let result = await resource.read(range: dataRange)
                
                await MainActor.run {
                    switch result {
                    case .success(let data):
                        ATLog(.debug, "✅ [LCPURLProtocol] Successfully read \(data.count) bytes for \(trackFilename)")
                        self.client?.urlProtocol(self, didLoad: data)
                        self.client?.urlProtocolDidFinishLoading(self)
                        
                    case .failure(let error):
                        ATLog(.error, "❌ [LCPURLProtocol] Failed to read data: \(error)")
                        self.client?.urlProtocol(self, didFailWithError: error)
                    }
                }
            }
        }
    }
    
    private func getContentLength(for resource: Resource, trackFilename: String) async throws -> UInt64 {
        // Try estimated length first (faster)
        let estimatedResult = await resource.estimatedLength()
        if case .success(let length) = estimatedResult, let length = length {
            ATLog(.debug, "📏 [LCPURLProtocol] Got estimated length: \(length) for \(trackFilename)")
            return length
        }
        
        // Fallback to properties
        let propertiesResult = await resource.properties()
        if case .success(let properties) = propertiesResult,
           let length = properties.properties["length"] as? UInt64 {
            ATLog(.debug, "📏 [LCPURLProtocol] Got length from properties: \(length) for \(trackFilename)")
            return length
        }
        
        ATLog(.debug, "📏 [LCPURLProtocol] No content length available for \(trackFilename), using fallback")
        return 0 // AVPlayer can handle unknown length
    }
    
    private func parseRangeHeader(_ rangeHeader: String) -> Range<UInt64>? {
        // Parse "bytes=start-end" format
        let components = rangeHeader.replacingOccurrences(of: "bytes=", with: "").components(separatedBy: "-")
        
        guard components.count == 2,
              let start = UInt64(components[0]),
              let end = UInt64(components[1]) else {
            ATLog(.debug, "⚠️ [LCPURLProtocol] Could not parse range header: \(rangeHeader)")
            return nil
        }
        
        return start..<(end + 1) // Convert to exclusive upper bound
    }
}

#endif 