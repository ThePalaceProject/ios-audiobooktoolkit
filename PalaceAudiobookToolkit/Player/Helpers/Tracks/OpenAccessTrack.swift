//
//  OpenAccessTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Darwin
import Foundation

// MARK: - OpenAccessTrackError

enum OpenAccessTrackError: Error {
  case invalidJSON
  case missingURL
  case missingDuration
  case unsupportedMediaType
  case other(String)

  var localizedDescription: String {
    switch self {
    case .invalidJSON: "Invalid or missing JSON data"
    case .missingURL: "Missing URL in JSON data"
    case .missingDuration: "Missing duration in JSON data"
    case .unsupportedMediaType: "Unsupported media type"
    case let .other(message): message
    }
  }
}

// MARK: - OpenAccessTrack

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

  public required init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    token: String? = nil,
    key: String?
  ) throws {
    guard let urlString, let url = URL(string: urlString)
    else {
      throw OpenAccessTrackError.unsupportedMediaType
    }

    self.audiobookID = audiobookID
    self.url = url
    urls = [url]
    self.urlString = urlString
    mediaType = manifest.trackMediaType
    self.key = key ?? "\(audiobookID)-\(index)"
    self.title = title ?? "Track \(index + 1)"
    self.index = index
    self.duration = duration
    alternateUrls = []
    feedbooksProfile = manifest.profile(for: .findaway)
    self.token = token
    downloadTask = OpenAccessDownloadTask(
      key: self.key,
      downloadURL: url,
      urlString: urlString,
      urlMediaType: mediaType,
      alternateLinks: alternateUrls,
      feedbooksProfile: feedbooksProfile,
      token: token
    )
  }
}
