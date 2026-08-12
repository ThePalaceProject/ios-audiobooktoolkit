//
//  LCPTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public final class LCPTrack: Track {
  public let key: String
  public let downloadTask: (any DownloadTask)?
  public let title: String?
  public let index: Int
  public let duration: TimeInterval
  public let urls: [URL]?
  public let mediaType: TrackMediaType
  /// Assigned after construction by `setStreamingResource(_:)`, so lock-guarded
  /// rather than `let` — every other property on this type is write-once in
  /// `init`. (`OverdriveTrack` has mutable members of its own; this is not the
  /// only one in the module.)
  ///
  /// - Warning: `setStreamingResource(_:)` has **zero callers** and this
  ///   property has **zero readers**, in the toolkit and in ios-core. It is
  ///   dead API that was carried through this migration rather than removed,
  ///   because deleting public surface is not a concurrency change. Tracked in
  ///   `docs/followups.md`.
  private let _streamingResource = LockIsolated<URL?>(nil)
  public var streamingResource: URL? {
    get { _streamingResource.value }
    set { _streamingResource.value = newValue }
  }

  public required init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    token _: String? = nil,
    key: String? = nil
  ) throws {
    guard let urlString else {
      throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
    }

    self.key = key ?? "\(audiobookID)-\(index)"
    urls = [URL(string: urlString)].compactMap { $0 }
    guard !(urls?.isEmpty ?? true) else {
      throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
    }

    self.title = title ?? "Track \(index + 1)"
    self.duration = duration
    self.index = index
    mediaType = manifest.trackMediaType

    downloadTask = LCPDownloadTask(key: self.key, urls: urls, mediaType: mediaType)
  }

  /// Set the streaming resource URL for this track
  public func setStreamingResource(_ url: URL?) {
    streamingResource = url
  }

  /// Check if this track has local files available
  public func hasLocalFiles() -> Bool {
    guard let lcpTask = downloadTask as? LCPDownloadTask,
          let decryptedUrls = lcpTask.decryptedUrls
    else {
      return false
    }
    return decryptedUrls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
  }
}
