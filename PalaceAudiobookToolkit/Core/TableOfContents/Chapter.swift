//
//  Chapter.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public class Chapter: NSObject {
    var title: String
    var position: TrackPosition
    var duration: Int?
    
    init(title: String, position: TrackPosition, duration: Int? = nil) {
        self.title = title
        self.position = position
        self.duration = duration
    }
}

public class TrackPosition: NSObject {
    var track: Track
    var timeStamp: Int
    var tracks: [Track]
    
    init(track: Track, timeStamp: Int, tracks: [Track]) {
        self.track = track
        self.timeStamp = timeStamp
        self.tracks = tracks
    }
}

public class Track: NSObject {
    var href: String
    var title: String?
    var duration: Int
    var index: Int
    var downloadTask: DownloadTask
    
    init(href: String, title: String? = nil, duration: Int, index: Int, downloadTask: DownloadTask) {
        self.href = href
        self.title = title
        self.duration = duration
        self.index = index
        self.downloadTask = downloadTask
    }
}
