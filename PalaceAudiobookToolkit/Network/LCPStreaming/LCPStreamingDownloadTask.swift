//
//  LCPStreamingDownloadTask.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import Combine

let LCPStreamingTaskCompleteNotification = NSNotification.Name(rawValue: "LCPStreamingTaskCompleteNotification")

/// LCPStreamingDownloadTask provides on-demand streaming for LCP audiobooks without pre-downloading files
public final class LCPStreamingDownloadTask: DownloadTask {
    public var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    
    /// For streaming, we don't pre-download, so progress is always 1.0 (ready to stream)
    public var downloadProgress: Float = 1.0
    
    public let key: String
    
    /// URL of the file inside the audiobook archive (e.g., `media/sound.mp3`)
    let urls: [URL]
    
    /// Streaming URLs that will be used by AVPlayer with custom resource loader
    var streamingUrls: [URL]? = []
    
    let urlMediaType: TrackMediaType
    
    /// Streaming tasks don't need retry since they fetch on-demand
    public  var needsRetry: Bool { false }
    
    init(key: String, urls: [URL]?, mediaType: TrackMediaType) {
        self.key = key
        self.urls = urls ?? []
        self.urlMediaType = mediaType
        self.streamingUrls = self.urls.compactMap { streamingURL(for: $0) }
        
        DispatchQueue.main.async {
            self.statePublisher.send(.completed)
        }
    }
    
    /// Converts a regular URL to a streaming URL with custom scheme
    /// - Parameter url: Original URL (e.g., `media/sound.mp3`)
    /// - Returns: Streaming URL with custom scheme (e.g., `lcp-stream://media/sound.mp3`)
    private func streamingURL(for url: URL) -> URL? {
        let streamingScheme = "lcp-stream"
        
        let cleanPath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let urlString = "\(streamingScheme)://\(key)/\(cleanPath)"
        
        ATLog(.debug, "[LCPStreaming] Generated streaming URL: '\(urlString)' for original URL: '\(url.absoluteString)'")
        
        guard let streamingURL = URL(string: urlString) else {
            ATLog(.error, "[LCPStreaming] Failed to create streaming URL from string: \(urlString)")
            return nil
        }
        
        return streamingURL
    }
    
    /// For streaming, we don't need to pre-fetch anything
    public func fetch() {
        downloadProgress = 1.0
        statePublisher.send(.completed)
    }
    
    /// Returns streaming URLs that can be used by AVPlayer with custom resource loader
    public func assetFileStatus() -> AssetResult {
        guard let streamingUrls = streamingUrls, !streamingUrls.isEmpty else {
            return .unknown
        }
        return .saved(streamingUrls)
    }
    
    /// For streaming, we don't have files to delete, but we can clear any cached ranges
    public func delete() {
        NotificationCenter.default.post(
            name: NSNotification.Name("LCPStreamingClearCache"),
            object: nil,
            userInfo: ["trackKey": key]
        )
        statePublisher.send(.deleted)
    }
    
    /// Cancel streaming preparation (no-op for streaming tasks)
    public func cancel() {}
    
    /// Original URLs from the manifest (for reference)
    var originalUrls: [URL] {
        return urls
    }
}

// MARK: - URL Helpers

extension LCPStreamingDownloadTask {
    /// Extract the original URL from a streaming URL
    /// - Parameter streamingURL: URL with lcp-stream:// scheme
    /// - Returns: Original URL path, or nil if not a valid streaming URL
    static func originalPath(from streamingURL: URL) -> String? {
        guard streamingURL.scheme == "lcp-stream" else { 
            ATLog(.error, "[LCPStreaming] Invalid scheme for streaming URL: \(streamingURL.scheme ?? "nil")")
            return nil 
        }
        
        let pathComponents = streamingURL.pathComponents
        ATLog(.debug, "[LCPStreaming] URL path components: \(pathComponents)")
        
        guard pathComponents.count > 1 else { 
            ATLog(.error, "[LCPStreaming] Insufficient path components in URL: \(streamingURL.absoluteString)")
            return nil 
        }
        
        let originalPath = pathComponents.dropFirst().joined(separator: "/")
        ATLog(.debug, "[LCPStreaming] Extracted original path: '\(originalPath)' from URL: \(streamingURL.absoluteString)")
        return originalPath
    }
    
    /// Extract the track key from a streaming URL
    /// - Parameter streamingURL: URL with lcp-stream:// scheme
    /// - Returns: Track key, or nil if not a valid streaming URL
    static func trackKey(from streamingURL: URL) -> String? {
        guard streamingURL.scheme == "lcp-stream" else { return nil }
        return streamingURL.host
    }
}

// MARK: - Migration Support

extension LCPStreamingDownloadTask {
    /// Create a streaming task from an existing LCPDownloadTask
    /// - Parameter downloadTask: Existing download task
    /// - Returns: New streaming task with same configuration
    static func migrate(from downloadTask: LCPDownloadTask) -> LCPStreamingDownloadTask {
        return LCPStreamingDownloadTask(
            key: downloadTask.key,
            urls: downloadTask.urls,
            mediaType: downloadTask.urlMediaType
        )
    }
    
    /// Check if we should use streaming or traditional download for a given media type
    /// - Parameter mediaType: The track media type
    /// - Returns: True if streaming should be used, false for traditional download
    static func shouldUseStreaming(for mediaType: TrackMediaType) -> Bool {
        switch mediaType {
        case .audioMP3, .audioMP4, .audioMPEG, .audioAAC:
            true
        case .rbDigital:
            false
        }
    }
} 
