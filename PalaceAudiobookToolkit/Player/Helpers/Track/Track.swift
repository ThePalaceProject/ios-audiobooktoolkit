//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

enum TrackMediaType: String {
    case audioMPEG = "audio/mpeg"
    case audioMP4 = "audio/mp4"
    case rbDigital = "vnd.librarysimplified/rbdigital-access-document+json"
    case audioMP3 = "audio/mp3"
    case audioAAC = "audio/aac"
}

public protocol Track: class, Identifiable {
    var key: String { get }
    var downloadTask: DownloadTask? { get }
    var title: String? { get }
    var index: Int { get }
    var duration: TimeInterval { get }
    var urls: [URL]? { get }
}

extension Track {
    public var id: String { key }
    
    public var description: String {
        let titleDesc = title ?? "Unknown Title"
        let urlsDesc = urls?.map { $0.absoluteString }.joined(separator: ", ") ?? "No URLs"
        return """
        Track Key: \(key)
        Title: \(titleDesc)
        Index: \(index)
        Duration: \(duration) seconds
        URLs: \(urlsDesc)
        """
    }
}
