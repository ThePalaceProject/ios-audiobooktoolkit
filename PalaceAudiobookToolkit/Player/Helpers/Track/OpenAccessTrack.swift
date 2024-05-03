//
//  OpenAccessTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Darwin
import Foundation

enum OpenAccessTrackError: Error {
    case invalidJSON
    case missingURL
    case missingDuration
    case unsupportedMediaType
    case other(String)
    
    var localizedDescription: String {
        switch self {
        case .invalidJSON: return "Invalid or missing JSON data"
        case .missingURL: return "Missing URL in JSON data"
        case .missingDuration: return "Missing duration in JSON data"
        case .unsupportedMediaType: return "Unsupported media type"
        case .other(let message): return message
        }
    }
}

public class OpenAccessTrack: Track {
    public var key: String
    public var downloadTask: DownloadTask?
    public var title: String?
    public var index: Int
    public var duration: Double
    public var url: URL?
    public var urls: [URL]?
    let mediaType: TrackMediaType
    let urlString: String
    let alternateUrls: [(TrackMediaType, URL)]?
    let audiobookID: String
    let feedbooksProfile: String?
    let token: String?

    required public init(
        manifest: Manifest,
        urlString: String?,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int,
        token: String? = nil
    ) throws {
        guard let urlString, let url = URL(string: urlString)
        else {
            throw OpenAccessTrackError.unsupportedMediaType
        }

        self.audiobookID = audiobookID
        self.url = url
        self.urls = [url]
        self.urlString = urlString
        self.mediaType = TrackMediaType(rawValue: manifest.formatType ?? "") ?? .audioMP4
        self.key = "\(audiobookID)-\(index)"
        self.title = title ?? "Track \(index + 1)"
        self.index = index
        self.duration = duration
        self.alternateUrls = []
        self.feedbooksProfile = nil
        self.token = token
        self.downloadTask = OpenAccessDownloadTask(
            key: key,
            downloadURL: url,
            urlString: urlString,
            urlMediaType: mediaType,
            alternateLinks: alternateUrls,
            feedbooksProfile: feedbooksProfile,
            token: token
        )

        //TODO: REturn to for feedbooks
//        // Feedbooks DRM or other configurations can be handled similarly
//        if let feedbooksProfile = manifest.properties?.encrypted.profile as? String,
//           feedbooksProfile.contains("feedbooks")
//        if let feedbooksProfile = payload["properties"]?["encrypted"]?["profile"] as? String,
//           feedbooksProfile.contains("feedbooks") {
//            // Handle DRM configuration if necessary
//        }
    }
}
