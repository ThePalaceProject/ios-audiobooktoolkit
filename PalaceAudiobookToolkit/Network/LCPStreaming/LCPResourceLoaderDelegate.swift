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
  
  /// Initialize with Readium Publication and decryption provider
  /// - Parameters:
  ///   - publication: The Readium Publication containing track information
  ///   - decryptor: LCP decryption provider
  ///   - rangeRetriever: HTTP range retriever for byte-range requests
  public init(publication: Publication, decryptor: LCPStreamingProvider, rangeRetriever: HTTPRangeRetriever) {
    self.publication = publication
    self.decryptor = decryptor
    self.rangeRetriever = rangeRetriever
    self.backgroundQueue = DispatchQueue(label: "lcp-resource-loader", qos: .userInitiated)
    
    super.init()
    
    ATLog(.debug, "LCPResourceLoaderDelegate initialized for publication: \(publication.metadata.title ?? "Unknown")")
  }
  
  // MARK: - AVAssetResourceLoaderDelegate
  
  public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    
    guard let url = loadingRequest.request.url else {
      ATLog(.error, "No URL in loading request")
      loadingRequest.finishLoading(with: NSError(domain: "LCPResourceLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "No URL in request"]))
      return false
    }
    
    ATLog(.debug, "Resource loading requested for URL: \(url)")
    
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
    
    // Handle the loading request asynchronously
    backgroundQueue.async { [weak self] in
      self?.handleLoadingRequest(loadingRequest, for: readingOrderItem, trackPath: trackPath)
    }
    
    return true
  }
  
  public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    ATLog(.debug, "Resource loading cancelled for: \(loadingRequest.request.url?.absoluteString ?? "unknown")")
  }
  
  // MARK: - Private Methods
  
  /// Extract track path from custom lcp-stream:// URL
  private func extractTrackPath(from url: URL) -> String? {
    // Expected format: lcp-stream://trackkey/path/to/audio.mp3
    guard url.scheme == "lcp-stream" else {
      return nil
    }
    
    // Remove the custom scheme and reconstruct the original path
    let pathComponents = url.pathComponents
    guard pathComponents.count > 1 else {
      return nil
    }
    
    // Join path components excluding the leading "/"
    let trackPath = pathComponents.dropFirst().joined(separator: "/")
    ATLog(.debug, "Extracted track path: \(trackPath)")
    return trackPath
  }
  
  /// Find reading order item in publication for the given track path
  private func findReadingOrderItem(for trackPath: String) -> Link? {
    // Search through publication's reading order for matching href
    for item in publication.readingOrder {
      if item.href.path == trackPath || item.href.path.hasSuffix(trackPath) {
        ATLog(.debug, "Found reading order item for track: \(trackPath)")
        return item
      }
    }
    
    ATLog(.warn, "No reading order item found for track: \(trackPath)")
    return nil
  }
  
  /// Handle the actual loading request with byte-range support
  private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest, for readingOrderItem: Link, trackPath: String) {
    
    // Get content information if requested
    if let contentInformationRequest = loadingRequest.contentInformationRequest {
      handleContentInformationRequest(contentInformationRequest, for: readingOrderItem)
    }
    
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
  private func handleContentInformationRequest(_ contentRequest: AVAssetResourceLoadingContentInformationRequest, for readingOrderItem: Link) {
    
    // Set content type for audio files
    if let mediaType = readingOrderItem.type {
      contentRequest.contentType = mediaType
      ATLog(.debug, "Set content type: \(mediaType)")
    } else {
      // Default to MP3 if no type specified
      contentRequest.contentType = "audio/mpeg"
    }
    
    // Set content length if available
    if let contentLength = readingOrderItem.properties.additionalProperties["contentLength"] as? Int64 {
      contentRequest.contentLength = contentLength
      ATLog(.debug, "Set content length: \(contentLength)")
    }
    
    // Enable byte range requests
    contentRequest.isByteRangeAccessSupported = true
  }
  
  /// Handle data request with byte-range support and LCP decryption
  private func handleDataRequest(_ loadingRequest: AVAssetResourceLoadingRequest, dataRequest: AVAssetResourceLoadingDataRequest, for readingOrderItem: Link, trackPath: String) {
    
    let requestedOffset = dataRequest.requestedOffset
    let requestedLength = dataRequest.requestedLength
    
    ATLog(.debug, "Data request for track: \(trackPath), offset: \(requestedOffset), length: \(requestedLength)")
    
    // Create range for HTTP request
    let range = requestedOffset..<(requestedOffset + Int64(requestedLength))
    
    // Get the actual URL for the reading order item
    guard let trackURL = resolveTrackURL(for: readingOrderItem) else {
      DispatchQueue.main.async {
        loadingRequest.finishLoading(with: NSError(domain: "LCPResourceLoader", code: -4, userInfo: [NSLocalizedDescriptionKey: "Could not resolve track URL"]))
      }
      return
    }
    
    // Perform byte-range request with decryption
    performByteRangeRequest(trackURL: trackURL, range: range) { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success(let data):
          // Provide decrypted data to AVPlayer
          dataRequest.respond(with: data)
          loadingRequest.finishLoading()
          ATLog(.debug, "Successfully provided \(data.count) bytes for track: \(trackPath)")
          
        case .failure(let error):
          ATLog(.error, "Failed to load data for track: \(trackPath), error: \(error)")
          loadingRequest.finishLoading(with: error)
        }
      }
    }
  }
  
  /// Resolve the actual URL for a reading order item
  private func resolveTrackURL(for item: Link) -> URL? {
    // The item.href should contain the relative path within the publication
    // We need to resolve this against the publication's base URL
    
    if let baseURL = publication.baseURL {
      return baseURL.appendingPathComponent(item.href.path)
    }
    
    // Fallback: try to construct URL from href
    return URL(string: item.href.path)
  }
  
  /// Perform byte-range HTTP request with LCP decryption
  private func performByteRangeRequest(trackURL: URL, range: Range<Int64>, completion: @escaping (Result<Data, Error>) -> Void) {
    
    // Use the publication to get the resource and decrypt the data
    guard let resource = publication.get(Link(href: trackURL.path)) else {
      completion(.failure(NSError(domain: "LCPResourceLoader", code: -5, userInfo: [NSLocalizedDescriptionKey: "Resource not found"])))
      return
    }
    
    // Convert range to UInt64 for Readium
    let readiumRange = UInt64(range.lowerBound)..<UInt64(range.upperBound)
    
    // Use Readium's resource reading with range
    Task {
      let result = await resource.read(range: readiumRange)
      
      switch result {
      case .success(let data):
        completion(.success(data))
      case .failure(let error):
        completion(.failure(error))
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


