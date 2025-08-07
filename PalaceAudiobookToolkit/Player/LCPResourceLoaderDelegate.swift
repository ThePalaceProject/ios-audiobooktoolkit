//
//  LCPResourceLoaderDelegate.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import ReadiumShared

/// LCPResourceLoaderDelegate handles AVPlayer resource loading requests for LCP streaming audiobooks
/// It intercepts custom URLs (lcp-stream://) and provides decrypted audio data on-demand
class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    
    private let httpRangeRetriever: HTTPRangeRetriever
    private let lcpPublication: Publication
    private let processingQueue = DispatchQueue(label: "com.palace.lcp-resource-loader", qos: .userInitiated)
    private var activeRequests: [String: AVAssetResourceLoadingRequest] = [:]
    private let requestsLock = NSLock()
    
    init(
        httpRangeRetriever: HTTPRangeRetriever,
        lcpPublication: Publication
    ) {
        self.httpRangeRetriever = httpRangeRetriever
        self.lcpPublication = lcpPublication
        super.init()
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == "lcp-stream" else {
            return false
        }
        
        let requestId = UUID().uuidString
        requestsLock.lock()
        activeRequests[requestId] = loadingRequest
        requestsLock.unlock()
        
        processingQueue.async { [weak self] in
            self?.handleLoadingRequest(loadingRequest, requestId: requestId)
        }
        
        return true
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        requestsLock.lock()
        let requestToRemove = activeRequests.first { $0.value === loadingRequest }
        if let key = requestToRemove?.key {
            activeRequests.removeValue(forKey: key)
        }
        requestsLock.unlock()
    }
    
    // MARK: - Request Handling
    
    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest, requestId: String) {
        defer {
            requestsLock.lock()
            activeRequests.removeValue(forKey: requestId)
            requestsLock.unlock()
        }
        
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Invalid URL"))
            return
        }
        
        
        // NOTE: LCPResourceLoaderDelegate is deprecated - using pure Readium streaming instead
        loadingRequest.finishLoading(with: NSError.resourceLoadingError("LCPResourceLoaderDelegate deprecated - use Readium streaming"))
    }
    
    /// Find the correct resource path in the publication using the same logic as LCPAudiobooks
    private func findResourcePath(_ originalPath: String) -> String? {
        if lcpPublication.getResource(at: originalPath) != nil {
            return originalPath
        }
        
        let pathWithSlash = originalPath.hasPrefix("/") ? originalPath : "/\(originalPath)"
        if lcpPublication.getResource(at: pathWithSlash) != nil {
            return pathWithSlash
        }
        
        let pathWithoutSlash = originalPath.hasPrefix("/") ? String(originalPath.dropFirst()) : originalPath
        if lcpPublication.getResource(at: pathWithoutSlash) != nil {
            return pathWithoutSlash
        }
        
        let decodedPath = originalPath.removingPercentEncoding ?? originalPath
        if decodedPath != originalPath && lcpPublication.getResource(at: decodedPath) != nil {
            return decodedPath
        }
        
        let filename = URL(string: originalPath)?.lastPathComponent ?? originalPath
        for link in lcpPublication.manifest.readingOrder {
            if let linkFilename = URL(string: link.href)?.lastPathComponent,
               linkFilename == filename {
                return link.href
            }
        }
        
        return nil
    }
    
    private func handleResourceRequest(_ loadingRequest: AVAssetResourceLoadingRequest, for path: String) {
        if let contentRequest = loadingRequest.contentInformationRequest {
            handleContentInformationRequest(contentRequest, for: path, loadingRequest: loadingRequest)
        }
        
        if let dataRequest = loadingRequest.dataRequest {
            handleDataRequest(dataRequest, for: path, loadingRequest: loadingRequest)
        }
        
        if loadingRequest.contentInformationRequest == nil && loadingRequest.dataRequest == nil {
            loadingRequest.finishLoading()
        }
    }
    
    private func handleContentInformationRequest(
        _ request: AVAssetResourceLoadingContentInformationRequest,
        for path: String,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        
        guard let resource = lcpPublication.getResource(at: path) else {
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Resource not found"))
            return
        }
                
        Task {
            do {
                let properties = try await resource.properties().get()
                var contentLength: Int64? = nil
                
                let id3Info = await getID3Info(for: resource)
                
                if let resourceLength = properties.length, resourceLength > 0 {
                    let virtualLength = Int64(resourceLength) - Int64(id3Info.audioOffset)
                    contentLength = max(0, virtualLength)
                } else {
                    if let probedSize = await probeActualFileSize(resource: resource) {
                        let virtualLength = Int64(probedSize) - Int64(id3Info.audioOffset)
                        contentLength = max(0, virtualLength)
                    } else {
                        contentLength = nil
                    }
                }
                
                DispatchQueue.main.async { [weak self] in
                    let contentType = self?.getContentType(for: path) ?? "audio/mpeg"
                    request.contentType = contentType
                    
                    request.isByteRangeAccessSupported = true
                    
                    if let length = contentLength {
                        request.contentLength = length
                    } else {
                        ATLog(.debug, "Content length unknown, letting AVPlayer handle dynamically")
                    }
                    
                    loadingRequest.finishLoading()
                }
            } catch {
                DispatchQueue.main.async {
                    loadingRequest.finishLoading(with: NSError.resourceLoadingError("Failed to get resource properties: \(error)"))
                }
            }
        }
    }
    
    private func getContentLengthViaHTTP(for path: String) async -> Int64? {
        do {
            guard let httpURL = getOriginalHTTPURL(for: path) else {
                return nil
            }
                        
            let httpRequest = HTTPRequest(url: httpURL, method: .head)
            let response = try await httpRangeRetriever.httpClient.fetch(httpRequest).get()
            
            if let contentLengthHeader = response.headers["Content-Length"] ?? response.headers["content-length"] {
                if let contentLength = Int64(contentLengthHeader) {
                    return contentLength
                }
            }
            
            return nil
            
        } catch {
            return nil
        }
    }
    
    private func getOriginalHTTPURL(for path: String) -> HTTPURL? {
        for link in lcpPublication.manifest.readingOrder {
            if link.href == path {
                if let baseURL = lcpPublication.manifest.metadata.identifier,
                   let url = URL(string: baseURL),
                   let httpURL = HTTPURL(string: url.appendingPathComponent(path).absoluteString) {
                    return httpURL
                }
                break
            }
        }
        
        if let httpURL = HTTPURL(string: "https://example.com/\(path)") {
            return httpURL
        }
        
        return nil
    }
    
    private func handleDataRequest(
        _ request: AVAssetResourceLoadingDataRequest,
        for path: String,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let resource = lcpPublication.getResource(at: path) else {
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Resource not found: \(path)"))
            return
        }
                
        Task {
            do {
                let properties = try await resource.properties().get()
           
                
                let id3Info = await getID3Info(for: resource)
                
                let currentOffset = request.currentOffset
                let requestedLength = request.requestedLength
                
                let physicalOffset = UInt64(currentOffset) + UInt64(id3Info.audioOffset)
                let startOffset = UInt64(max(id3Info.audioOffset, Int(physicalOffset)))
                
                var actualFileSize: UInt64? = nil
                if let resourceLength = properties.length, resourceLength > 0 {
                    actualFileSize = resourceLength
                } else {
                    actualFileSize = await probeActualFileSize(resource: resource)
                }
                
                let range: Range<UInt64>
                if requestedLength == 0 {
                    if let fileSize = actualFileSize {
                        let clampedEnd = min(fileSize, startOffset + 1024*1024)
                        range = startOffset..<clampedEnd
                    } else {
                        range = startOffset..<(startOffset + 1024*1024)
                    }
                } else {
                    let endOffset = startOffset + UInt64(requestedLength)
                    
                    if let fileSize = actualFileSize {
                        let clampedEnd = min(endOffset, fileSize)
                        range = startOffset..<clampedEnd
                    } else {
                        let maxChunkSize: UInt64 = 10 * 1024 * 1024
                        let safeEnd = min(endOffset, startOffset + maxChunkSize)
                        range = startOffset..<safeEnd
                    }
                }
                
                guard range.lowerBound < range.upperBound else {
                    DispatchQueue.main.async {
                        loadingRequest.finishLoading(with: NSError.resourceLoadingError("Invalid range"))
                    }
                    return
                }
                
                var streamedData = Data()
                let streamResult = await resource.stream(range: range) { data in
                    streamedData.append(data)
                }
                
                guard case .success = streamResult else {
                    throw NSError.resourceLoadingError("Failed to stream data from LCP resource")
                }
                
                let decryptedData = streamedData
                                
                if decryptedData.count > 0 {
                    let headerBytes = decryptedData.prefix(min(8, decryptedData.count))
                    let headerHex = headerBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    
                    if headerBytes.count >= 2 {
                        let firstByte = headerBytes[headerBytes.startIndex]
                        let secondByte = headerBytes[headerBytes.index(after: headerBytes.startIndex)]
                    }
                }
                
                guard !decryptedData.isEmpty else {
                    DispatchQueue.main.async {
                        loadingRequest.finishLoading(with: NSError.resourceLoadingError("No data available"))
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    request.respond(with: decryptedData)
                    loadingRequest.finishLoading()
                }
                
            } catch {
                DispatchQueue.main.async {
                    loadingRequest.finishLoading(with: NSError.resourceLoadingError("Failed to read data: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    /// Probe the actual file size by attempting to read at various offsets
    private func probeActualFileSize(resource: Resource) async -> UInt64? {
        let estimatedResult = await resource.estimatedLength()
        if case .success(let estimatedLength) = estimatedResult, let length = estimatedLength {
            return length
        }
        
        let stepSize: UInt64 = 5 * 1024 * 1024
        var currentOffset: UInt64 = 0
        var lastValidOffset: UInt64 = 0
        
        while currentOffset < 50 * 1024 * 1024 {
            let range = currentOffset..<(currentOffset + 1024)
            
            var dataReceived = false
            let result = await resource.stream(range: range) { data in
                dataReceived = !data.isEmpty
            }
            
            if case .success = result, dataReceived {
                lastValidOffset = currentOffset + 1024
                currentOffset += stepSize
            } else {
                break
            }
        }
        
        if lastValidOffset == 0 {
            return nil
        }
        
        var low = lastValidOffset
        var high = currentOffset
        var actualFileSize = lastValidOffset
                
        while low + 1024 < high {
            let mid = low + (high - low) / 2
            
            let range = mid..<(mid + 1024)
            
            var dataReceived = false
            let result = await resource.stream(range: range) { data in
                dataReceived = !data.isEmpty
            }
            
            if case .success = result, dataReceived {
                actualFileSize = mid + 1024
                low = mid
            } else {
                high = mid
            }
        }
        
        return actualFileSize
    }
    
    private func getID3Info(for resource: Resource) async -> (hasTag: Bool, size: Int, audioOffset: Int) {
        do {
            let headerData = try await resource.read(range: 0..<64).get()
            
            if headerData.count >= 10 && headerData.starts(with: "ID3".data(using: .ascii)!) {
                let sizeBytes = Array(headerData[6..<10])
                var tagSize = 0
                for byte in sizeBytes {
                    tagSize = (tagSize << 7) | Int(byte & 0x7F)
                }
                tagSize += 10
                
                return (hasTag: true, size: tagSize, audioOffset: tagSize)
            }
        } catch {
            ATLog(.debug, "Could not read header for ID3 detection: \(error)")
        }
        
        return (hasTag: false, size: 0, audioOffset: 0)
    }
    
    // MARK: - Decryption Support
    
    private func getContentType(for path: String) -> String {
        if path.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        } else if path.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        } else if path.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        } else {
            // Default to audio/mpeg for unknown types
            return "audio/mpeg"
        }
    }
}

// MARK: - Error Extensions

private extension NSError {
    static func resourceLoadingError(_ message: String) -> NSError {
        return NSError(
            domain: "LCPResourceLoaderError",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - Publication Extension

private extension Publication {
    func getResource(at path: String) -> Resource? {
        // Try the path as-is first
        let resource = get(Link(href: path))
        guard type(of: resource) != FailureResource.self else {
            // Try with leading slash
            return get(Link(href: "/" + path))
        }
        return resource
    }
}

private let filenameKey = "https://readium.org/webpub-manifest/properties#filename"
private let mediaTypeKey = "https://readium.org/webpub-manifest/properties#mediaType"

public extension ResourceProperties {
    /// The length of the resource in bytes, if provided.
    var contentLength: Int64? {
        get {
            // Readium tends to use "length" or "contentLength" as the key
            if let u64 = properties["length"] as? UInt64 {
                return Int64(u64)
            }
            if let i64 = properties["contentLength"] as? Int64 {
                return i64
            }
            return nil
        }
        set {
            if let v = newValue {
                properties["length"] = UInt64(v)
            } else {
                properties.removeValue(forKey: "length")
            }
        }
    }
    
    /// The length of the resource in bytes, if provided (UInt64 version).
    var length: UInt64? {
        get {
            if let u64 = properties["length"] as? UInt64 {
                return u64
            }
            if let i64 = properties["contentLength"] as? Int64 {
                return UInt64(i64)
            }
            return nil
        }
        set {
            if let v = newValue {
                properties["length"] = v
            } else {
                properties.removeValue(forKey: "length")
            }
        }
    }
    
    /// The MIME type for this resource, if provided.
    var contentType: String? {
        get {
            // `mediaType` comes from your existing extension
            return mediaType?.rawValue
        }
        set {
            if let mime = newValue {
                properties[mediaTypeKey] = mime
            } else {
                properties.removeValue(forKey: mediaTypeKey)
            }
        }
    }
}


