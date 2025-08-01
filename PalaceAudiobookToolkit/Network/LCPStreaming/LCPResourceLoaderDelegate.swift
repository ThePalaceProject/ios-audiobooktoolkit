//
//  LCPResourceLoaderDelegate.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import ReadiumShared

#if LCP

/// LCP Resource Loader Delegate for handling decrypted audio streaming
/// This class implements AVAssetResourceLoaderDelegate to provide decrypted
/// audio data for streaming LCP audiobooks using Readium's streaming architecture
public class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
  
  private let publication: Publication
  private let decryptor: LCPStreamingProvider
  private let rangeRetriever: HTTPRangeRetriever
  private let backgroundQueue: DispatchQueue
  private let streamingBaseURL: URL  // 🚀 Base URL for streaming (from license)
  
  // Cache content lengths to avoid repeated requests
  private var contentLengthCache: [String: Int64] = [:]
  private let cacheQueue = DispatchQueue(label: "content-length-cache", attributes: .concurrent)
  
  // Track active loading requests to prevent conflicts
  private var activeRequests: Set<String> = []
  private let requestQueue = DispatchQueue(label: "lcp-resource-requests", qos: .userInitiated)
  private let requestLock = NSLock()
  
  /// Initialize with Readium Publication and decryption provider
  /// - Parameters:
  ///   - publication: The Readium Publication containing track information
  ///   - decryptor: LCP decryption provider
  ///   - rangeRetriever: HTTP range retriever for byte-range requests
  ///   - streamingBaseURL: Base URL for streaming (extracted from license)
  public init(publication: Publication, decryptor: LCPStreamingProvider, rangeRetriever: HTTPRangeRetriever, streamingBaseURL: URL) {
    self.publication = publication
    self.decryptor = decryptor
    self.rangeRetriever = rangeRetriever
    self.streamingBaseURL = streamingBaseURL
    self.backgroundQueue = DispatchQueue(label: "lcp-resource-loader", qos: .userInitiated)
    
    super.init()
    
    ATLog(.debug, "LCPResourceLoaderDelegate initialized for publication: \(publication.metadata.title ?? "Unknown")")
  }
  
  // MARK: - AVAssetResourceLoaderDelegate
  
  public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    ATLog(.debug, "🔥 [LCPResourceLoaderDelegate] resourceLoader called!")
    
    guard let url = loadingRequest.request.url else {
      ATLog(.error, "🔥 [LCPResourceLoaderDelegate] No URL in loading request")
      loadingRequest.finishLoading(with: NSError(domain: "LCPResourceLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "No URL in request"]))
      return false
    }
    
    ATLog(.debug, "🔥 [LCPResourceLoaderDelegate] Resource loading requested for URL: \(url)")
    
    // Extract track path from custom URL scheme
    guard let trackPath = extractTrackPath(from: url) else {
      ATLog(.error, "Failed to extract track path from URL: \(url)")
      loadingRequest.finishLoading(with: NSError(domain: "LCPResourceLoader", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL format"]))
      return false
    }
    
    // Find the reading order item for this track
    guard let readingOrderItem = findReadingOrderItem(for: trackPath) else {
      ATLog(.error, "No reading order item found for track: \(trackPath)")
      loadingRequest.finishLoading(with: NSError(domain: "LCPResourceLoader", code: -3, userInfo: [NSLocalizedDescriptionKey: "Track not found in publication"]))
      return false
    }
    
    // Create unique request ID for tracking
    let requestID = "\(trackPath)-\(arc4random())"
    
    // Handle the loading request asynchronously with thread-safe tracking
    requestQueue.async { [weak self] in
      self?.handleLoadingRequestSafely(loadingRequest, for: readingOrderItem, trackPath: trackPath, requestID: requestID)
    }
    
    return true
  }
  
  public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    ATLog(.debug, "Resource loading cancelled for: \(loadingRequest.request.url?.absoluteString ?? "unknown")")
  }
  
  // MARK: - Private Methods
  
  /// Extract track path from custom readium-lcp:// URL
  private func extractTrackPath(from url: URL) -> String? {
    // Expected format: readium-lcp://trackkey/path/to/audio.mp3
    guard url.scheme == "readium-lcp" else {
      ATLog(.debug, "URL scheme is not readium-lcp: \(url.scheme ?? "nil")")
      return nil
    }
    
    // Remove the custom scheme and reconstruct the original path
    let pathComponents = url.pathComponents
    guard pathComponents.count > 1 else {
      ATLog(.debug, "Not enough path components: \(pathComponents)")
      return nil
    }
    
    // Join path components excluding the leading "/" and track key
    // Format: readium-lcp://track0/filename.mp3 -> filename.mp3
    let trackPath = pathComponents.dropFirst(2).joined(separator: "/")
    if trackPath.isEmpty {
      // Fallback: use the last component if joining fails
      let fallbackPath = pathComponents.last ?? ""
      ATLog(.debug, "Using fallback track path: \(fallbackPath)")
      return fallbackPath
    }
    
    ATLog(.debug, "Extracted track path: \(trackPath)")
    return trackPath
  }
  
  /// Find reading order item in publication for the given track path
  private func findReadingOrderItem(for trackPath: String) -> Link? {
    // Search through publication's reading order for matching href
    for item in publication.readingOrder {
      if item.href == trackPath || item.href.hasSuffix(trackPath) {
        ATLog(.debug, "Found reading order item for track: \(trackPath)")
        return item
      }
    }
    
    ATLog(.warn, "No reading order item found for track: \(trackPath)")
    return nil
  }
  
  /// Handle loading request with thread-safe tracking to prevent concurrent conflicts
  private func handleLoadingRequestSafely(_ loadingRequest: AVAssetResourceLoadingRequest, for readingOrderItem: Link, trackPath: String, requestID: String) {
    
    // 🔒 Thread-safe request tracking
    requestLock.lock()
    
    // Check if this track is already being processed
    if activeRequests.contains(trackPath) {
      ATLog(.debug, "🚦 [LCPResourceLoader] Track \(trackPath) already loading, queueing request \(requestID)")
      requestLock.unlock()
      
      // Queue this request for later processing
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.handleLoadingRequestSafely(loadingRequest, for: readingOrderItem, trackPath: trackPath, requestID: requestID)
      }
      return
    }
    
    // Mark this track as active
    activeRequests.insert(trackPath)
    requestLock.unlock()
    
    ATLog(.debug, "🎯 [LCPResourceLoader] Starting request \(requestID) for track: \(trackPath)")
    
    // Process the request
    handleLoadingRequest(loadingRequest, for: readingOrderItem, trackPath: trackPath)
    
    // Remove from active requests when complete
    DispatchQueue.main.async { [weak self] in
      self?.requestLock.lock()
      self?.activeRequests.remove(trackPath)
      self?.requestLock.unlock()
      ATLog(.debug, "✅ [LCPResourceLoader] Completed request \(requestID) for track: \(trackPath)")
    }
  }
  
  /// Handle the actual loading request with byte-range support
  private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest, for readingOrderItem: Link, trackPath: String) {
    
    // Handle content information first if requested
    if let contentInformationRequest = loadingRequest.contentInformationRequest {
      handleContentInformationRequest(contentInformationRequest, for: readingOrderItem) { [weak self] in
        // Content information is ready, now handle data request
        self?.handleDataRequestAfterContentInfo(loadingRequest, for: readingOrderItem, trackPath: trackPath)
      }
    } else {
      // No content information requested, go straight to data
      handleDataRequestAfterContentInfo(loadingRequest, for: readingOrderItem, trackPath: trackPath)
    }
  }
  
  /// Handle data request after content information is ready
  private func handleDataRequestAfterContentInfo(_ loadingRequest: AVAssetResourceLoadingRequest, for readingOrderItem: Link, trackPath: String) {
    // Handle data request with byte-range support
    if let dataRequest = loadingRequest.dataRequest {
      handleDataRequest(loadingRequest, dataRequest: dataRequest, for: readingOrderItem, trackPath: trackPath)
    } else {
      // If no data request, just finish loading
      DispatchQueue.main.async {
        loadingRequest.finishLoading()
      }
    }
  }
  
  /// Handle content information request (file size, content type, etc.)
  private func handleContentInformationRequest(_ contentRequest: AVAssetResourceLoadingContentInformationRequest, for readingOrderItem: Link, completion: @escaping () -> Void) {
    
    // Set content type for audio files
    if let mediaType = readingOrderItem.mediaType {
      contentRequest.contentType = mediaType.string
      ATLog(.debug, "🎯 [LCPResourceLoader] Set content type: \(mediaType.string)")
    } else {
      // Default to MP3 if no type specified
      contentRequest.contentType = "audio/mpeg"
      ATLog(.debug, "🎯 [LCPResourceLoader] Set default content type: audio/mpeg")
    }
    
    // Enable byte range requests
    contentRequest.isByteRangeAccessSupported = true
    ATLog(.debug, "🎯 [LCPResourceLoader] Enabled byte range access")
    
    // Set content length by getting it from the streaming URL
    getContentLength(for: readingOrderItem) { [weak self] contentLength in
      DispatchQueue.main.async {
        if let length = contentLength {
          contentRequest.contentLength = length
          ATLog(.debug, "🎯 [LCPResourceLoader] Set content length: \(length) bytes for track: \(readingOrderItem.href)")
        } else {
          ATLog(.debug, "🎯 [LCPResourceLoader] Could not determine content length for track: \(readingOrderItem.href)")
        }
        // Call completion handler whether we got length or not
        completion()
      }
    }
  }
  
  /// Handle data request with byte-range support and LCP decryption
  private func handleDataRequest(_ loadingRequest: AVAssetResourceLoadingRequest, dataRequest: AVAssetResourceLoadingDataRequest, for readingOrderItem: Link, trackPath: String) {
    
    let requestedOffset = dataRequest.requestedOffset
    let requestedLength = dataRequest.requestedLength
    
    ATLog(.debug, "🎯 [LCPResourceLoader] Data request: offset=\(requestedOffset), length=\(requestedLength) for track: \(trackPath)")
    
    // 🎯 SMART STREAMING: Balance between responsiveness and memory efficiency  
    // Allow reasonable chunks but prevent massive requests that cause crashes
    let maxChunkSize: Int64 = 2 * 1024 * 1024 // 2MB max chunk - prevents crashes while allowing good streaming
    let actualLength = min(Int64(requestedLength), maxChunkSize)
    let range = requestedOffset..<(requestedOffset + actualLength)
    
    if actualLength != Int64(requestedLength) {
      ATLog(.debug, "🎯 [LCPResourceLoader] Limited request: \(actualLength) bytes (requested: \(requestedLength)) to prevent memory issues")
    } else {
      ATLog(.debug, "🎯 [LCPResourceLoader] Fulfilling full request: \(actualLength) bytes from offset \(requestedOffset)")
    }
    
    // Perform byte-range request with decryption using Readium
    performByteRangeRequestDirect(href: trackPath, range: range) { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success(let data):
          // Provide decrypted data to AVPlayer
          dataRequest.respond(with: data)
          
          // 🎯 SMART COMPLETION: Only finish loading if we provided ALL requested data
          if actualLength == Int64(requestedLength) {
            // We provided everything requested - safe to finish
            loadingRequest.finishLoading()
            ATLog(.debug, "✅ [LCPResourceLoader] Completed full request: \(data.count) bytes for track: \(trackPath)")
          } else {
            // We provided partial data due to chunk limiting - DON'T finish, let AVPlayer request more
            ATLog(.debug, "🔄 [LCPResourceLoader] Provided limited chunk: \(data.count) bytes (of \(requestedLength) requested) for track: \(trackPath)")
          }
          
        case .failure(let error):
          ATLog(.error, "❌ [LCPResourceLoader] Failed to load \(actualLength) bytes for track: \(trackPath), error: \(error)")
          loadingRequest.finishLoading(with: error)
        }
      }
    }
  }
  
  /// Resolve the actual URL for a reading order item
  private func resolveTrackURL(for item: Link) -> URL? {
    // Use the streaming base URL (from license) with the track's href
    let streamingURL = streamingBaseURL.appendingPathComponent(item.href)
    ATLog(.debug, "🔗 Resolved streaming URL: '\(item.href)' -> '\(streamingURL.absoluteString)'")
    return streamingURL
  }
  
  /// Perform byte-range request using Readium's Publication with LCP decryption (direct href)
  private func performByteRangeRequestDirect(href: String, range: Range<Int64>, completion: @escaping (Result<Data, Error>) -> Void) {
    
    ATLog(.debug, "🎯 [LCPResourceLoader] Using href for direct publication.get(): \(href)")
    
    // Use the publication to get the resource and decrypt the data
    guard let resource = publication.get(Link(href: href)) else {
      ATLog(.error, "🎯 [LCPResourceLoader] Resource not found for href: \(href)")
      completion(.failure(NSError(domain: "LCPResourceLoader", code: -5, userInfo: [NSLocalizedDescriptionKey: "Resource not found"])))
      return
    }
    
    ATLog(.debug, "🎯 [LCPResourceLoader] Found resource for href: \(href)")
    
    // Convert range to UInt64 for Readium
    let readiumRange = UInt64(range.lowerBound)..<UInt64(range.upperBound)
    
    // Use Readium's resource reading with range
    Task {
      ATLog(.debug, "🎯 [LCPResourceLoader] Reading range \(readiumRange.lowerBound)-\(readiumRange.upperBound) (\(readiumRange.count) bytes)")
      let result = await resource.read(range: readiumRange)
      
      switch result {
      case .success(let data):
        ATLog(.debug, "🎯 [LCPResourceLoader] Successfully read \(data.count) bytes from Readium resource")
        completion(.success(data))
      case .failure(let error):
        ATLog(.error, "🎯 [LCPResourceLoader] Failed to read from Readium resource: \(error)")
        completion(.failure(error))
      }
    }
  }
  
  /// Perform byte-range request using Readium's Publication with LCP decryption (legacy method)
  private func performByteRangeRequest(trackURL: URL, range: Range<Int64>, completion: @escaping (Result<Data, Error>) -> Void) {
    
    // Extract the relative href from the trackURL path
    let href = trackURL.lastPathComponent
    ATLog(.debug, "🎯 [LCPResourceLoader] Using href for publication.get(): \(href)")
    
    // Use the publication to get the resource and decrypt the data
    guard let resource = publication.get(Link(href: href)) else {
      ATLog(.error, "🎯 [LCPResourceLoader] Resource not found for href: \(href)")
      completion(.failure(NSError(domain: "LCPResourceLoader", code: -5, userInfo: [NSLocalizedDescriptionKey: "Resource not found"])))
      return
    }
    
    ATLog(.debug, "🎯 [LCPResourceLoader] Found resource for href: \(href)")
    
    // Convert range to UInt64 for Readium
    let readiumRange = UInt64(range.lowerBound)..<UInt64(range.upperBound)
    
    // Use Readium's resource reading with range
    Task {
      ATLog(.debug, "🎯 [LCPResourceLoader] Reading range \(readiumRange.lowerBound)-\(readiumRange.upperBound) (\(readiumRange.count) bytes)")
      let result = await resource.read(range: readiumRange)
      
      switch result {
      case .success(let data):
        ATLog(.debug, "🎯 [LCPResourceLoader] Successfully read \(data.count) bytes from Readium resource")
        completion(.success(data))
      case .failure(let error):
        ATLog(.error, "🎯 [LCPResourceLoader] Failed to read from Readium resource: \(error)")
        completion(.failure(error))
      }
    }
  }
  
  /// Get content length for a reading order item using Readium's Publication
  private func getContentLength(for item: Link, completion: @escaping (Int64?) -> Void) {
    let trackPath = item.href
    
    // Check cache first
    cacheQueue.sync {
      if let cachedLength = contentLengthCache[trackPath] {
        ATLog(.debug, "🎯 [LCPResourceLoader] Using cached content length \(cachedLength) for track: \(trackPath)")
        completion(cachedLength)
        return
      }
    }
    
    ATLog(.debug, "🎯 [LCPResourceLoader] Getting content length for href: \(trackPath)")
    
    // Use Readium's Publication to get the resource
    guard let resource = publication.get(Link(href: trackPath)) else {
      ATLog(.debug, "🎯 [LCPResourceLoader] Resource not found for content length: \(trackPath)")
      completion(nil)
      return
    }
    
    // 🎯 Get content length using Readium's resource system (not HTTP HEAD requests)
    ATLog(.debug, "🎯 [LCPResourceLoader] Getting content length for LCP track using Readium: \(trackPath)")
    
    // Use Readium's resource to get the length asynchronously
    Task {
      // Try estimatedLength first (faster)
      let lengthResult = await resource.estimatedLength()
      
      switch lengthResult {
      case .success(let optionalLength):
        if let length = optionalLength {
          let length64 = Int64(length)
          ATLog(.debug, "🎯 [LCPResourceLoader] Retrieved content length \(length64) from Readium estimatedLength: \(trackPath)")
          
          // Cache the result
          await MainActor.run {
            self.cacheQueue.async(flags: .barrier) {
              self.contentLengthCache[trackPath] = length64
            }
            completion(length64)
          }
          return
        }
        
        // Fall back to properties if estimatedLength returned nil
        ATLog(.debug, "🎯 [LCPResourceLoader] estimatedLength returned nil, trying properties for: \(trackPath)")
        let propertiesResult = await resource.properties()
        
        switch propertiesResult {
        case .success(let properties):
          if let length = properties.properties["length"] as? UInt64 {
            let length64 = Int64(length)
            ATLog(.debug, "🎯 [LCPResourceLoader] Retrieved content length \(length64) from Readium properties: \(trackPath)")
            
            await MainActor.run {
              self.cacheQueue.async(flags: .barrier) {
                self.contentLengthCache[trackPath] = length64
              }
              completion(length64)
            }
          } else {
            ATLog(.debug, "🎯 [LCPResourceLoader] No length found in properties for: \(trackPath)")
            await MainActor.run { completion(nil) }
          }
        case .failure(let error):
          ATLog(.error, "🎯 [LCPResourceLoader] Failed to get properties from Readium resource: \(trackPath), error: \(error)")
          await MainActor.run { completion(nil) }
        }
        
      case .failure(let error):
        ATLog(.error, "🎯 [LCPResourceLoader] Failed to get estimatedLength from Readium resource: \(trackPath), error: \(error)")
        await MainActor.run { completion(nil) }
      }
    }
  }
  
  /// Decrypt data using LCP decryptor (simplified - actual decryption handled by Readium)
  private func decryptData(_ encryptedData: Data, completion: @escaping (Result<Data, Error>) -> Void) {
    // With Readium's LCP integration, the resource.read() already returns decrypted data
    // So we can pass through the data directly
    completion(.success(encryptedData))
  }
}

#endif


