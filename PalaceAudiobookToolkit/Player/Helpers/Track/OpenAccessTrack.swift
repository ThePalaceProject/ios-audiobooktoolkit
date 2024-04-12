//
//  OpenAccessTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Darwin
import Foundation

enum OpenAccessTrackMediaType: String {
    case audioMPEG = "audio/mpeg"
    case audioMP4 = "audio/mp4"
    case rbDigital = "vnd.librarysimplified/rbdigital-access-document+json"
}

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
    public let url: URL
    let mediaType: OpenAccessTrackMediaType
    let urlString: String // Retain original URI for DRM purposes
    let alternateUrls: [(OpenAccessTrackMediaType, URL)]?
    let audiobookID: String
    let feedbooksProfile: String?
    let token: String?

    init(manifest: Manifest, urlString: String, audiobookID: String, title: String?, duration: Double, index: Int, token: String? = nil) throws {
        guard let url = URL(string: urlString)
        else {
            throw OpenAccessTrackError.unsupportedMediaType
        }

        self.audiobookID = audiobookID
        self.url = url
        self.urlString = urlString
        self.mediaType = OpenAccessTrackMediaType(rawValue: manifest.formatType ?? "") ?? .audioMP4
        self.key = "\(audiobookID)-\(index)"
        self.title = title ?? "Track \(index + 1)"
        self.index = index
        self.duration = duration
        self.downloadTask = URLDownloadTask(url: url, key: self.key)
        self.alternateUrls = []
        self.feedbooksProfile = nil
        self.token = token
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
