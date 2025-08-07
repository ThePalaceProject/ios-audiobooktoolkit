//
//  LCPTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

class LCPTrack: Track {
    var key: String
    var downloadTask: (any DownloadTask)?
    var title: String?
    var index: Int
    var duration: TimeInterval
    var urls: [URL]?
    let mediaType: TrackMediaType
    
    /// Streaming resource for this track (from Readium when available)
    var streamingResource: URL?
    

    
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

        self.downloadTask = LCPDownloadTask(key: self.key, urls: urls, mediaType: mediaType)
    }
    
    /// Set the streaming resource URL for this track
    func setStreamingResource(_ url: URL?) {
        self.streamingResource = url
    }
    
    /// Check if this track has local files available
    func hasLocalFiles() -> Bool {
        guard let lcpTask = downloadTask as? LCPDownloadTask,
              let decryptedUrls = lcpTask.decryptedUrls else {
            return false
        }
        return decryptedUrls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

}
