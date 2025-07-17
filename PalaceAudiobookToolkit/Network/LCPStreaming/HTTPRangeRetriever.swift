//
//  HTTPRangeRetriever.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

/// HTTPRangeRetriever provides HTTP range request support for streaming resources
/// This replaces RangeAssetRetriever to avoid AssetRetriever extension issues
public class HTTPRangeRetriever {
    private let httpClient: HTTPClient
    private let cacheManager: RangeCacheManager
    
    public init(httpClient: HTTPClient = DefaultHTTPClient()) {
        self.httpClient = httpClient
        self.cacheManager = RangeCacheManager()
    }
    
    /// Performs a range request for a specific byte range of a resource
    /// - Parameters:
    ///   - url: The URL to fetch from
    ///   - range: The byte range to fetch (start..<end)
    ///   - completion: Completion handler with the requested data
    public func fetchRange(
        from url: AbsoluteURL,
        range: Range<Int>,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // Check cache first
        if let cachedData = cacheManager.getCachedRange(for: url, range: range) {
            completion(.success(cachedData))
            return
        }
      
        guard let httpURL = url.httpURL else {
            completion(.failure(NSError(domain: "HTTPRangeRetrieverError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP URL"])))
            return
        }
        
        Task {
            do {
                let request = HTTPRequest(
                    url: httpURL,
                    method: .get,
                    headers: [
                        "Range": "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
                    ]
                )
                
                let response = try await httpClient.stream(request: request)
                
                switch response {
                case .success(let resource):
                    let data = try await resource.read().get()
                    
                    // Cache the fetched range
                    cacheManager.cacheRange(for: url, range: range, data: data)
                    completion(.success(data))
                    
                case .failure(let error):
                    completion(.failure(error))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    /// Fetches the total content length of a resource via HEAD request
    /// - Parameters:
    ///   - url: The URL to check
    ///   - completion: Completion handler with the content length
    public func getContentLength(
        for url: AbsoluteURL,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard let httpURL = url.httpURL else {
            completion(.failure(NSError(domain: "HTTPRangeRetrieverError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP URL"])))
            return
        }
        
        Task {
            do {
                let request = HTTPRequest(url: httpURL, method: .head)
                let response = try await httpClient.stream(request: request)
                
                switch response {
                case .success(let resource):
                    let properties = try await resource.properties().get()
                    let length = Int(properties.length ?? 0)
                    completion(.success(length))
                    
                case .failure(let error):
                    completion(.failure(error))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    /// Create a RangeResource for a given URL
    /// - Parameter url: The URL to create a resource for
    /// - Returns: A RangeResource instance
    public func createResource(for url: AbsoluteURL) -> RangeResource {
        return RangeResource(sourceURL: url, httpClient: httpClient)
    }
}

/// Cache manager for HTTP range requests to avoid redundant network calls
private class RangeCacheManager {
    private var cache: [String: [Range<Int>: Data]] = [:]
    private let cacheQueue = DispatchQueue(label: "com.palace.range-cache", attributes: .concurrent)
    private let maxCacheSize = 50 * 1024 * 1024 // 50MB max cache
    private var currentCacheSize = 0
    
    func getCachedRange(for url: AbsoluteURL, range: Range<Int>) -> Data? {
        return cacheQueue.sync {
            guard let urlCache = cache[url.string] else { return nil }
            
            // Check if we have the exact range
            if let data = urlCache[range] {
                return data
            }
            
            // Check if any cached range contains our requested range
            for (cachedRange, cachedData) in urlCache {
                if cachedRange.contains(range.lowerBound) && cachedRange.contains(range.upperBound - 1) {
                    let startOffset = range.lowerBound - cachedRange.lowerBound
                    let length = range.count
                    return cachedData.subdata(in: startOffset..<(startOffset + length))
                }
            }
            
            return nil
        }
    }
    
    func cacheRange(for url: AbsoluteURL, range: Range<Int>, data: Data) {
        cacheQueue.async(flags: .barrier) {
            if self.currentCacheSize + data.count > self.maxCacheSize {
                self.evictOldestEntries(toFree: data.count)
            }
            
            if self.cache[url.string] == nil {
                self.cache[url.string] = [:]
            }
            
            self.cache[url.string]?[range] = data
            self.currentCacheSize += data.count
        }
    }
    
    private func evictOldestEntries(toFree spaceNeeded: Int) {
        var freedSpace = 0
        var urlsToRemove: [String] = []
        
        for (url, ranges) in cache {
            for (_, data) in ranges {
                freedSpace += data.count
            }
            urlsToRemove.append(url)
            
            if freedSpace >= spaceNeeded {
                break
            }
        }
        
        for url in urlsToRemove {
            cache.removeValue(forKey: url)
        }
        
        currentCacheSize = max(0, currentCacheSize - freedSpace)
    }
} 