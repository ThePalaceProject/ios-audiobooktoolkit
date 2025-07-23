//
//  LCPStreamingTrack.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

/// LCPStreamingTrack implements the Track protocol for LCP audiobooks using streaming instead of pre-download
class LCPStreamingTrack: Track {
    var key: String
    var downloadTask: (any DownloadTask)?
    var title: String?
    var index: Int
    var duration: TimeInterval
    var urls: [URL]?
    let mediaType: TrackMediaType
    
    required init(
        manifest: Manifest,
        urlString: String?,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int,
        token: String? = nil,
        key: String? = nil
    ) throws {
        guard let urlString else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }

        self.key = key ?? "\(audiobookID)-\(index)"
        self.urls = [URL(string: urlString)].compactMap { $0 }
        guard !(self.urls?.isEmpty ?? true) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }

        self.title = title ?? "Track \(index + 1)"
        self.duration = duration
        self.index = index
        self.mediaType = manifest.trackMediaType
        
        // Use streaming download task if streaming is enabled and supported
        if LCPStreamingDownloadTask.shouldUseStreaming(for: mediaType) {
            self.downloadTask = LCPStreamingDownloadTask(key: self.key, urls: urls, mediaType: mediaType)
            ATLog(.debug, "[LCPStreaming] Created streaming track: \(self.key)")
        } else {
            // Fallback to traditional LCP download task
            self.downloadTask = LCPDownloadTask(key: self.key, urls: urls, mediaType: mediaType)
            ATLog(.debug, "[LCPStreaming] Created traditional LCP track (streaming not available): \(self.key)")
        }
    }
    
    /// Check if this track is configured for streaming
    var isStreaming: Bool {
        return downloadTask is LCPStreamingDownloadTask
    }
    
    /// Get the streaming URLs if available
    var streamingUrls: [URL]? {
        guard let streamingTask = downloadTask as? LCPStreamingDownloadTask else {
            return nil
        }
        return streamingTask.streamingUrls
    }
    
    /// Get the original URLs from the manifest
    var originalUrls: [URL]? {
        if let streamingTask = downloadTask as? LCPStreamingDownloadTask {
            return streamingTask.originalUrls
        } else if let lcpTask = downloadTask as? LCPDownloadTask {
            return lcpTask.urls
        }
        return urls
    }
} 