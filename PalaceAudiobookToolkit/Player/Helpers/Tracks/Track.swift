//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - TrackMediaType

public enum TrackMediaType: String, Sendable {
  case audioMPEG = "audio/mpeg"
  case audioMP4 = "audio/mp4"
  case rbDigital = "vnd.librarysimplified/rbdigital-access-document+json"
  case audioMP3 = "audio/mp3"
  case audioAAC = "audio/aac"
}

// MARK: - Track

/// Refines `Sendable` so that `TrackPosition` — which carries a track and is
/// passed between the player, the download scheduler and the UI on different
/// threads — can be `Sendable` in turn.
///
/// This is sound because a track is immutable once constructed: every conformer
/// declares its stored properties `let`, assigned during `init` and never
/// reassigned (verified across the whole module). The one piece of genuinely
/// mutable state a track exposes is `downloadTask`, and that is a reference to
/// a type which is itself `Sendable` and internally synchronized.
///
/// - Note: `AnyObject` replaces the deprecated `class` spelling.
public protocol Track: AnyObject, Identifiable, Sendable {
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

/// The fifth `Track` conformer — easy to miss because it lives here rather than
/// alongside the others in `Tracks/`. Immutable like the rest.
final class EmptyTrack: Track {
  let key: String
  let downloadTask: (any DownloadTask)?
  let title: String?
  let index: Int
  let duration: TimeInterval
  let urls: [URL]?
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
    key = ""
    downloadTask = nil
    urls = nil
    self.title = title
    self.duration = duration
    self.index = index
  }

  init() {
    key = ""
    downloadTask = nil
    urls = nil
    title = ""
    index = 0
    duration = 0.0
  }
}
