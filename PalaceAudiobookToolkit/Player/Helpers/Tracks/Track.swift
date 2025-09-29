//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - TrackMediaType

public enum TrackMediaType: String {
  case audioMPEG = "audio/mpeg"
  case audioMP4 = "audio/mp4"
  case rbDigital = "vnd.librarysimplified/rbdigital-access-document+json"
  case audioMP3 = "audio/mp3"
  case audioAAC = "audio/aac"
}

// MARK: - Track

public protocol Track: class, Identifiable {
  var key: String { get }
  var downloadTask: DownloadTask? { get }
  var title: String? { get }
  var index: Int { get }
  var duration: TimeInterval { get }
  var partNumber: Int? { get }
  var chapterNumber: Int? { get }
  var urls: [URL]? { get }
  var downloadProgress: Float { get }

  init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    token: String?,
    key: String?
  ) throws
}

public extension Track {
  var id: String { key }
  var partNumber: Int? { nil }
  var chapterNumber: Int? { nil }

  var description: String {
    let titleDesc = title ?? "Unknown Title"
    let urlsDesc = urls?.map(\.absoluteString).joined(separator: ", ") ?? "No URLs"
    return """
    Track Key: \(key)
    Title: \(titleDesc)
    Index: \(index)
    Duration: \(duration) seconds
    URLs: \(urlsDesc)
    """
  }

  var downloadProgress: Float {
    downloadTask?.downloadProgress ?? 0.0
  }
}

// MARK: - EmptyTrack

class EmptyTrack: Track {
  var key: String = ""
  var downloadTask: (any DownloadTask)?
  var title: String? = ""
  var index: Int = 0
  var duration: TimeInterval = 0.0
  var urls: [URL]?
  required init(
    manifest _: Manifest,
    urlString _: String?,
    audiobookID _: String,
    title: String?,
    duration: Double,
    index: Int,
    token _: String?,
    key _: String?
  ) throws {
    self.title = title
    self.duration = duration
    self.index = index
  }

  init() {}
}
