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
            ATLog(.error, "[LCPStreaming] Invalid URL scheme: \(loadingRequest.request.url?.absoluteString ?? "nil")")
            return false
        }
        
        ATLog(.debug, "[LCPStreaming] Handling resource request for: \(url.absoluteString)")
        
        // Store the request for potential cancellation
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
        ATLog(.debug, "[LCPStreaming] Cancelled resource request")
        
        requestsLock.lock()
        // Find and remove the cancelled request
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
            ATLog(.error, "[LCPStreaming] Invalid URL in loading request")
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Invalid URL"))
            return
        }
        
        ATLog(.debug, "[LCPStreaming] Processing request for URL: \(url.absoluteString)")
        
        do {
            // Extract the original file path from the streaming URL
            guard let originalPath = LCPStreamingDownloadTask.originalPath(from: url) else {
                ATLog(.error, "[LCPStreaming] Could not extract original path from URL: \(url.absoluteString)")
                loadingRequest.finishLoading(with: NSError.resourceLoadingError("Invalid streaming URL format"))
                return
            }
            
            ATLog(.debug, "[LCPStreaming] Extracted original path: '\(originalPath)' from URL: '\(url.absoluteString)'")
            
            // Find the resource using the same logic as LCPAudiobooks.getResource
            guard let resolvedPath = findResourcePath(originalPath) else {
                ATLog(.error, "[LCPStreaming] Resource not found in LCP publication: '\(originalPath)'")
                ATLog(.debug, "[LCPStreaming] Available resources in publication:")
                for resource in lcpPublication.manifest.readingOrder {
                    ATLog(.debug, "[LCPStreaming]   - \(resource.href)")
                }
                
                loadingRequest.finishLoading(with: NSError.resourceLoadingError("Resource not found: \(originalPath)"))
                return
            }
            
            ATLog(.debug, "[LCPStreaming] Successfully resolved path '\(originalPath)' to '\(resolvedPath)'")
            handleResourceRequest(loadingRequest, for: resolvedPath)
            
        } catch {
            ATLog(.error, "[LCPStreaming] Error processing loading request: \(error.localizedDescription)")
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Request processing failed: \(error.localizedDescription)"))
        }
    }
    
    /// Find the correct resource path in the publication using the same logic as LCPAudiobooks
    private func findResourcePath(_ originalPath: String) -> String? {
        // Use the same getResource logic as LCPAudiobooks extension
        if lcpPublication.getResource(at: originalPath) != nil {
            ATLog(.debug, "[LCPStreaming] Found resource with direct path: '\(originalPath)'")
            return originalPath
        }
        
        // Try with leading slash
        let pathWithSlash = originalPath.hasPrefix("/") ? originalPath : "/\(originalPath)"
        if lcpPublication.getResource(at: pathWithSlash) != nil {
            ATLog(.debug, "[LCPStreaming] Found resource with leading slash: '\(pathWithSlash)'")
            return pathWithSlash
        }
        
        // Try without leading slash
        let pathWithoutSlash = originalPath.hasPrefix("/") ? String(originalPath.dropFirst()) : originalPath
        if lcpPublication.getResource(at: pathWithoutSlash) != nil {
            ATLog(.debug, "[LCPStreaming] Found resource without leading slash: '\(pathWithoutSlash)'")
            return pathWithoutSlash
        }
        
        // Try URL decoding in case there are encoded characters
        let decodedPath = originalPath.removingPercentEncoding ?? originalPath
        if decodedPath != originalPath && lcpPublication.getResource(at: decodedPath) != nil {
            ATLog(.debug, "[LCPStreaming] Found resource with URL-decoded path: '\(decodedPath)'")
            return decodedPath
        }
        
        // Try matching by just the filename (last path component)
        let filename = URL(string: originalPath)?.lastPathComponent ?? originalPath
        for link in lcpPublication.manifest.readingOrder {
            if let linkFilename = URL(string: link.href)?.lastPathComponent,
               linkFilename == filename {
                ATLog(.debug, "[LCPStreaming] Found resource by filename match: '\(link.href)' matches '\(filename)'")
                return link.href
            }
        }
        
        // Log all available resources for debugging
        ATLog(.debug, "[LCPStreaming] Could not find resource for path: '\(originalPath)'")
        ATLog(.debug, "[LCPStreaming] Available resources in manifest:")
        for (index, link) in lcpPublication.manifest.readingOrder.enumerated() {
            ATLog(.debug, "[LCPStreaming]   [\(index)] href: '\(link.href)'")
        }
        
        return nil
    }
    
    private func handleResourceRequest(_ loadingRequest: AVAssetResourceLoadingRequest, for path: String) {
        // Handle content information request
        if let contentRequest = loadingRequest.contentInformationRequest {
            handleContentInformationRequest(contentRequest, for: path, loadingRequest: loadingRequest)
        }
        
        // Handle data request
        if let dataRequest = loadingRequest.dataRequest {
            handleDataRequest(dataRequest, for: path, loadingRequest: loadingRequest)
        }
        
        // If neither request type is present, log a warning
        if loadingRequest.contentInformationRequest == nil && loadingRequest.dataRequest == nil {
            ATLog(.debug, "[LCPStreaming] Loading request has no content or data request")
            loadingRequest.finishLoading()
        }
    }
    
    private func handleContentInformationRequest(
      _ request: AVAssetResourceLoadingContentInformationRequest,
      for path: String,
      loadingRequest: AVAssetResourceLoadingRequest
    ) {
        ATLog(.debug, "[LCPStreaming] Handling content information request for path: \(path)")
        
        // Get the resource from the LCP publication to determine properties
        guard let resource = lcpPublication.getResource(at: path) else {
            ATLog(.error, "[LCPStreaming] Resource not found in publication: \(path)")
            ATLog(.debug, "[LCPStreaming] Available resources: \(lcpPublication.manifest.readingOrder.map { $0.href })")
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Resource not found"))
            return
        }
        
        ATLog(.debug, "[LCPStreaming] Found resource for content info: \(path)")
        
        Task {
            do {
                // Try to get properties from the resource first
                let properties = try await resource.properties().get()
                ATLog(.debug, "[LCPStreaming] Resource properties - length: \(properties.length ?? 0)")
                
                var contentLength: Int64? = nil
                
                // Get ID3 info to calculate the virtual content length (excluding ID3 tag)
                let id3Info = await getID3Info(for: resource)
                ATLog(.debug, "[LCPStreaming] ID3 info for content length calc - hasTag: \(id3Info.hasTag), size: \(id3Info.size), audioOffset: \(id3Info.audioOffset)")
                
                // Check if we have a valid content length from resource properties
                if let resourceLength = properties.length, resourceLength > 0 {
                    // Subtract ID3 tag size to get the virtual MP3 file size that AVPlayer should see
                    let virtualLength = Int64(resourceLength) - Int64(id3Info.audioOffset)
                    contentLength = max(0, virtualLength) // Ensure non-negative
                    ATLog(.debug, "[LCPStreaming] Original file size: \(resourceLength), ID3 offset: \(id3Info.audioOffset), Virtual content length: \(contentLength!)")
                } else {
                    // Resource doesn't have length info - try to probe the actual file size
                    ATLog(.debug, "[LCPStreaming] Resource properties missing length, probing file size...")
                    if let probedSize = await probeActualFileSize(resource: resource) {
                        // Subtract ID3 tag size to get the virtual MP3 file size that AVPlayer should see
                        let virtualLength = Int64(probedSize) - Int64(id3Info.audioOffset)
                        contentLength = max(0, virtualLength) // Ensure non-negative
                        ATLog(.debug, "[LCPStreaming] Probed file size: \(probedSize), ID3 offset: \(id3Info.audioOffset), Virtual content length: \(contentLength!)")
                    } else {
                        ATLog(.debug, "[LCPStreaming] Failed to probe file size, content length will be unknown")
                        contentLength = nil
                    }
                }
                
                DispatchQueue.main.async { [weak self] in
                    // Set content type based on file extension
                    let contentType = self?.getContentType(for: path) ?? "audio/mpeg"
                    ATLog(.debug, "[LCPStreaming] Setting content type: \(contentType)")
                    request.contentType = contentType
                    
                    // Always enable byte range access
                    request.isByteRangeAccessSupported = true
                    
                    // Set content length if available
                    if let length = contentLength {
                        request.contentLength = length
                        ATLog(.debug, "[LCPStreaming] Set content length: \(length) bytes")
                    } else {
                        ATLog(.debug, "[LCPStreaming] Content length unknown, letting AVPlayer handle dynamically")
                        // Don't set contentLength - let AVPlayer handle unknown length
                        // This often works better than setting length to 0
                    }
                    
                    loadingRequest.finishLoading()
                    ATLog(.debug, "[LCPStreaming] Completed content information request for: \(path)")
                }
            } catch {
                ATLog(.error, "[LCPStreaming] Failed to get resource properties: \(error)")
                DispatchQueue.main.async {
                    loadingRequest.finishLoading(with: NSError.resourceLoadingError("Failed to get resource properties: \(error)"))
                }
            }
        }
    }
    
    /// Attempt to get content length via HTTP HEAD request
    private func getContentLengthViaHTTP(for path: String) async -> Int64? {
        do {
            // Get the original HTTP URL for this resource
            guard let httpURL = getOriginalHTTPURL(for: path) else {
                ATLog(.error, "[LCPStreaming] Could not determine HTTP URL for path: \(path)")
                return nil
            }
            
            ATLog(.debug, "[LCPStreaming] Attempting HEAD request to: \(httpURL)")
            
            // Make HEAD request to get content length
            let httpRequest = HTTPRequest(url: httpURL, method: .head)
            let response = try await httpRangeRetriever.httpClient.fetch(httpRequest).get()
            
            if let contentLengthHeader = response.headers["Content-Length"] ?? response.headers["content-length"] {
                if let contentLength = Int64(contentLengthHeader) {
                    ATLog(.debug, "[LCPStreaming] Got content length from HTTP headers: \(contentLength)")
                    return contentLength
                }
            }
            
            ATLog(.debug, "[LCPStreaming] HTTP HEAD request did not provide Content-Length header")
            return nil
            
        } catch {
            ATLog(.error, "[LCPStreaming] HTTP HEAD request failed: \(error)")
            return nil
        }
    }
    
    /// Get the original HTTP URL for a resource path
    private func getOriginalHTTPURL(for path: String) -> HTTPURL? {
        // Try to find the resource in the manifest to get its original URL
        for link in lcpPublication.manifest.readingOrder {
            if link.href == path {
                // Try to construct HTTP URL from the publication's base URL
                if let baseURL = lcpPublication.manifest.metadata.identifier,
                   let url = URL(string: baseURL),
                   let httpURL = HTTPURL(string: url.appendingPathComponent(path).absoluteString) {
                    return httpURL
                }
                break
            }
        }
        
        // Fallback: try to construct URL using common patterns
        // This is a best-effort approach for when we can't determine the exact URL
        if let httpURL = HTTPURL(string: "https://example.com/\(path)") {
            ATLog(.debug, "[LCPStreaming] Using fallback HTTP URL construction")
            return httpURL
        }
        
        return nil
    }
    
    private func handleDataRequest(
        _ request: AVAssetResourceLoadingDataRequest,
        for path: String,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        ATLog(.debug, "[LCPStreaming] ===== HANDLING DATA REQUEST =====")
        ATLog(.debug, "[LCPStreaming] Requested path: \(path)")
        ATLog(.debug, "[LCPStreaming] Requested offset: \(request.requestedOffset)")
        ATLog(.debug, "[LCPStreaming] Requested length: \(request.requestedLength)")
        ATLog(.debug, "[LCPStreaming] Current offset: \(request.currentOffset)")
        
        // Get the resource from the LCP publication
        guard let resource = lcpPublication.getResource(at: path) else {
            ATLog(.error, "[LCPStreaming] Resource not found for data request: \(path)")
            ATLog(.debug, "[LCPStreaming] Available resources: \(lcpPublication.manifest.readingOrder.map { $0.href })")
            loadingRequest.finishLoading(with: NSError.resourceLoadingError("Resource not found: \(path)"))
            return
        }
        
        ATLog(.debug, "[LCPStreaming] Checking resource properties...")
        
        Task {
            do {
                // Get resource properties to determine actual file size
                let properties = try await resource.properties().get()
                ATLog(.debug, "[LCPStreaming] Resource properties - length: \(properties.length ?? 0)")
                
                if properties.length == nil || properties.length == 0 {
                    ATLog(.debug, "[LCPStreaming] ⚠️ Resource does not provide length information")
                }
                
                // Check for ID3 tag and adjust offset for proper mapping
                let id3Info = await getID3Info(for: resource)
                ATLog(.debug, "[LCPStreaming] ID3 info - hasTag: \(id3Info.hasTag), size: \(id3Info.size), audioOffset: \(id3Info.audioOffset)")
                
                // Calculate the actual reading parameters
                let currentOffset = request.currentOffset
                let requestedLength = request.requestedLength
                
                // Map AVPlayer's logical offset to physical offset in encrypted file
                // AVPlayer expects MP3 audio data at offset 0, but encrypted file has ID3 tag first
                let physicalOffset = UInt64(currentOffset) + UInt64(id3Info.audioOffset)
                ATLog(.debug, "[LCPStreaming] Mapping logical offset \(currentOffset) to physical offset \(physicalOffset) (ID3 offset: \(id3Info.audioOffset))")
                ATLog(.debug, "[LCPStreaming] Reading \(requestedLength) bytes from LCP resource")
                
                // Validate and clamp the range to prevent arithmetic overflow
                let startOffset = UInt64(max(id3Info.audioOffset, Int(physicalOffset)))
                ATLog(.debug, "[LCPStreaming] Range validation: start=\(startOffset), end=\(startOffset + UInt64(requestedLength))")
                
                // Try to determine actual file size for range validation
                var actualFileSize: UInt64? = nil
                if let resourceLength = properties.length, resourceLength > 0 {
                    actualFileSize = resourceLength
                    ATLog(.debug, "[LCPStreaming] Using resource properties for file size: \(actualFileSize!)")
                } else {
                    // Try to probe the file size by reading small chunks until we hit EOF
                    actualFileSize = await probeActualFileSize(resource: resource)
                    if let size = actualFileSize {
                        ATLog(.debug, "[LCPStreaming] Probed actual file size: \(size)")
                    }
                }
                
                // Build the safe range
                let range: Range<UInt64>
                if requestedLength == 0 {
                    // If length is 0, read from offset to end (but clamp to actual file size)
                    if let fileSize = actualFileSize {
                        let clampedEnd = min(fileSize, startOffset + 1024*1024) // Read up to 1MB chunks for streaming
                        range = startOffset..<clampedEnd
                        ATLog(.debug, "[LCPStreaming] Reading to end, clamped range: \(range)")
                    } else {
                        // Fallback: read a reasonable chunk size
                        range = startOffset..<(startOffset + 1024*1024)
                        ATLog(.debug, "[LCPStreaming] Unknown file size, reading 1MB chunk: \(range)")
                    }
                } else {
                    let endOffset = startOffset + UInt64(requestedLength)
                    
                    if let fileSize = actualFileSize {
                        // Clamp the end offset to not exceed actual file size
                        let clampedEnd = min(endOffset, fileSize)
                        range = startOffset..<clampedEnd
                        
                        if clampedEnd < endOffset {
                            ATLog(.debug, "[LCPStreaming] ⚠️ Requested range exceeds file size, clamped: \(startOffset)..<\(clampedEnd) (was \(startOffset)..<\(endOffset))")
                        } else {
                            ATLog(.debug, "[LCPStreaming] Range within file bounds: \(range)")
                        }
                    } else {
                        // No file size info, use requested range but limit to reasonable size
                        let maxChunkSize: UInt64 = 10 * 1024 * 1024 // 10MB max
                        let safeEnd = min(endOffset, startOffset + maxChunkSize)
                        range = startOffset..<safeEnd
                        ATLog(.debug, "[LCPStreaming] No file size available, using safe range: \(range)")
                    }
                }
                
                ATLog(.debug, "[LCPStreaming] Reading range: \(range.lowerBound)..<\(range.upperBound)")
                
                // Verify range is valid
                guard range.lowerBound < range.upperBound else {
                    ATLog(.error, "[LCPStreaming] Invalid range: \(range)")
                    DispatchQueue.main.async {
                        loadingRequest.finishLoading(with: NSError.resourceLoadingError("Invalid range"))
                    }
                    return
                }
                
                // Read the data using the resource's stream method
                // The LCP resource handles decryption automatically in its stream implementation
                var streamedData = Data()
                let streamResult = await resource.stream(range: range) { data in
                    streamedData.append(data)
                }
                
                guard case .success = streamResult else {
                    throw NSError.resourceLoadingError("Failed to stream data from LCP resource")
                }
                
                let decryptedData = streamedData
                
                ATLog(.debug, "[LCPStreaming] Successfully read \(decryptedData.count) bytes from resource")
                
                // Log the first few bytes to verify MP3 header
                if decryptedData.count > 0 {
                    let headerBytes = decryptedData.prefix(min(8, decryptedData.count))
                    let headerHex = headerBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    ATLog(.debug, "[LCPStreaming] First \(headerBytes.count) bytes: \(headerHex)")
                    
                    // Check for MP3 frame sync (should start with 0xFF 0xFB, 0xFF 0xFA, or 0xFF 0xF3 for MP3)
                    if headerBytes.count >= 2 {
                        let firstByte = headerBytes[headerBytes.startIndex]
                        let secondByte = headerBytes[headerBytes.index(after: headerBytes.startIndex)]
                        
                        if firstByte == 0xFF && (secondByte & 0xF0) == 0xF0 {
                            ATLog(.debug, "[LCPStreaming] Valid MP3 frame sync detected")
                        } else {
                            ATLog(.debug, "[LCPStreaming] MP3 frame sync not detected - first bytes: 0x\(String(format: "%02X", firstByte)) 0x\(String(format: "%02X", secondByte))")
                        }
                    }
                }
                
                // Verify we got some data
                guard !decryptedData.isEmpty else {
                    ATLog(.error, "[LCPStreaming] Received empty data from resource")
                    DispatchQueue.main.async {
                        loadingRequest.finishLoading(with: NSError.resourceLoadingError("No data available"))
                    }
                    return
                }
                
                // Provide the data to the loading request on the main thread
                DispatchQueue.main.async {
                    request.respond(with: decryptedData)
                    loadingRequest.finishLoading()
                    ATLog(.debug, "[LCPStreaming] Completed data request for \(decryptedData.count) bytes")
                }
                
            } catch {
                ATLog(.error, "[LCPStreaming] Failed to read resource data: \(error.localizedDescription)")
                ATLog(.error, "[LCPStreaming] Error details: \(error)")
                
                DispatchQueue.main.async {
                    loadingRequest.finishLoading(with: NSError.resourceLoadingError("Failed to read data: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    /// Probe the actual file size by attempting to read at various offsets
    private func probeActualFileSize(resource: Resource) async -> UInt64? {
        ATLog(.debug, "[LCPStreaming] Probing actual file size using Resource.estimatedLength() first")
        
        // First try to get the estimated length from the resource itself
        // LCP resources may provide this information directly
        let estimatedResult = await resource.estimatedLength()
        if case .success(let estimatedLength) = estimatedResult, let length = estimatedLength {
            ATLog(.debug, "[LCPStreaming] Resource provided estimated length: \(length)")
            return length
        }
        
        ATLog(.debug, "[LCPStreaming] No estimated length available, using binary search with Resource.stream()")
        
        // Fall back to binary search using the resource's stream method
        let stepSize: UInt64 = 5 * 1024 * 1024 // 5MB steps
        var currentOffset: UInt64 = 0
        var lastValidOffset: UInt64 = 0
        
        // Find rough upper bound
        while currentOffset < 50 * 1024 * 1024 { // Max 50MB
            do {
                let range = currentOffset..<(currentOffset + 1024) // Try 1KB
                
                var dataReceived = false
                let result = await resource.stream(range: range) { data in
                    dataReceived = !data.isEmpty
                }
                
                if case .success = result, dataReceived {
                    lastValidOffset = currentOffset + 1024
                    ATLog(.debug, "[LCPStreaming] Stream probe successful at offset \(currentOffset)")
                    currentOffset += stepSize
                } else {
                    ATLog(.debug, "[LCPStreaming] Stream probe failed at \(currentOffset / (1024*1024))MB")
                    break
                }
            } catch {
                ATLog(.debug, "[LCPStreaming] Stream probe failed at \(currentOffset / (1024*1024))MB: \(error)")
                break
            }
        }
        
        if lastValidOffset == 0 {
            ATLog(.debug, "[LCPStreaming] No successful stream probe, cannot determine file size")
            return nil
        }
        
        // Binary search to find the exact end of data
        var low = lastValidOffset
        var high = currentOffset
        var actualFileSize = lastValidOffset
        
        ATLog(.debug, "[LCPStreaming] Binary searching stream range between \(low) and \(high)")
        
        while low + 1024 < high { // Stop when range is small enough
            let mid = low + (high - low) / 2
            
            do {
                let range = mid..<(mid + 1024) // Try 1KB at midpoint
                
                var dataReceived = false
                let result = await resource.stream(range: range) { data in
                    dataReceived = !data.isEmpty
                }
                
                if case .success = result, dataReceived {
                    actualFileSize = mid + 1024
                    low = mid
                    ATLog(.debug, "[LCPStreaming] Binary search: stream at \(mid) successful")
                } else {
                    high = mid
                    ATLog(.debug, "[LCPStreaming] Binary search: stream at \(mid) failed")
                }
            } catch {
                high = mid
                ATLog(.debug, "[LCPStreaming] Binary search: stream at \(mid) failed with error: \(error)")
            }
        }
        
        ATLog(.debug, "[LCPStreaming] Binary search completed. Actual file size: \(actualFileSize)")
        return actualFileSize
    }
    
    /// Get ID3 tag information for proper offset handling
    private func getID3Info(for resource: Resource) async -> (hasTag: Bool, size: Int, audioOffset: Int) {
        do {
            // Read first 64 bytes to check for ID3v2 tag
            let headerData = try await resource.read(range: 0..<64).get()
            
            if headerData.count >= 10 && headerData.starts(with: "ID3".data(using: .ascii)!) {
                // ID3v2 tag found - calculate size
                let sizeBytes = Array(headerData[6..<10])
                var tagSize = 0
                for byte in sizeBytes {
                    tagSize = (tagSize << 7) | Int(byte & 0x7F)
                }
                tagSize += 10 // Add header size
                
                ATLog(.debug, "[LCPStreaming] ID3v2 tag detected for \(resource): size=\(tagSize), audio starts at offset \(tagSize)")
                return (hasTag: true, size: tagSize, audioOffset: tagSize)
            }
        } catch {
            ATLog(.debug, "[LCPStreaming] Could not read header for ID3 detection: \(error)")
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


