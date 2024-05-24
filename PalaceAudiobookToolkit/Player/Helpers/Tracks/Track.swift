//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public enum TrackMediaType: String {
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
    var partNumber: Int? { get }
    var chapterNumber: Int? { get }
    var urls: [URL]? { get }

    init(
        manifest: Manifest,
        urlString: String?,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int,
        token: String?
    ) throws
}

extension Track {
    public var id: String { key }
    public var partNumber: Int? { nil }
    public var chapterNumber: Int? { nil }

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

class EmptyTrack: Track {
    var key: String = ""
    var downloadTask: (any DownloadTask)? = nil
    var title: String? = ""
    var index: Int = 0
    var duration: TimeInterval = 0.0
    var urls: [URL]? = nil
    required init(
        manifest: Manifest,
        urlString: String?,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int,
        token: String?
    ) throws {
        self.title = title
        self.duration = duration
        self.index = index
    }
    
    init() {}
}
