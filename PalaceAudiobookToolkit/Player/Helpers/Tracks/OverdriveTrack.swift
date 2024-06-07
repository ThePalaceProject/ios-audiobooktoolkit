//
//  OverdriveTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/26/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

class OverdriveTrack: Track {

    var key: String = ""
    var downloadTask: (any DownloadTask)?
    var title: String?
    var index: Int
    var duration: TimeInterval
    var url: URL
    var urls: [URL]? { [url] }
    let mediaType: TrackMediaType
    
    required init(
        manifest: Manifest,
        urlString: String?,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int,
        token: String? = nil,
        key: String?
    ) throws {
        guard let urlString, let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }

        self.key = "urn:org.thepalaceproject:readingOrder:\(String(describing: index)))"
        self.url = url
        self.title = title
        self.index = index
        self.duration = duration
        self.mediaType = manifest.trackMediaType
        self.downloadTask = OverdriveDownloadTask(key: self.key, url: url, mediaType: mediaType)
    }
}
