//
//  LCPStreamingTrack.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

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
        
        if LCPStreamingDownloadTask.shouldUseStreaming(for: mediaType) {
            self.downloadTask = LCPStreamingDownloadTask(key: self.key, urls: urls, mediaType: mediaType)
            ATLog(.debug, "[LCPStreaming] Created streaming track: \(self.key)")
        } else {
            self.downloadTask = LCPDownloadTask(key: self.key, urls: urls, mediaType: mediaType)
            ATLog(.debug, "[LCPStreaming] Created traditional LCP track (streaming not available): \(self.key)")
        }
    }
    
    var isStreaming: Bool {
        return downloadTask is LCPStreamingDownloadTask
    }
    
    var streamingUrls: [URL]? {
        guard let streamingTask = downloadTask as? LCPStreamingDownloadTask else {
            return nil
        }
        return streamingTask.streamingUrls
    }
    
    var originalUrls: [URL]? {
        if let streamingTask = downloadTask as? LCPStreamingDownloadTask {
            return streamingTask.originalUrls
        } else if let lcpTask = downloadTask as? LCPDownloadTask {
            return lcpTask.urls
        }
        return urls
    }
} 
