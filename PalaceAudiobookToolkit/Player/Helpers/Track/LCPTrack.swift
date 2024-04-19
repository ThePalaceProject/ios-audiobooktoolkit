//
//  LCPTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

enum LCPTrackMediaType: String, Codable {
    case audioMP3 = "audio/mp3"
    case audioAAC = "audio/aac"
    case audioMPEG = "audio/mpeg"
}

class LCPTrack: Track {
    var key: String
    var downloadTask: (any DownloadTask)?
    var title: String?
    var index: Int
    var duration: TimeInterval
    var urls: [URL]?
    let mediaType: LCPTrackMediaType
    
    init(manifest: Manifest, urlString: String, audiobookID: String, title: String?, duration: Double, index: Int, token: String? = nil) throws {
        self.key = "\(audiobookID)-\(index)"
        self.urls = [URL(string: urlString)].compactMap { $0 }
        guard !(self.urls?.isEmpty ?? true) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }

        self.title = title ?? "Track \(index + 1)"
        self.duration = duration
        self.index = index
        if let mediaTypeString = manifest.readingOrder?.first?.type,
           let mediaType = LCPTrackMediaType(rawValue: mediaTypeString) {
            self.mediaType = mediaType
        } else {
            self.mediaType = .audioMP3
        }
        
        self.downloadTask = LCPDownloadTask(track: self)
    }
}
