//
//  OverdriveTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/26/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation

/// - Note: `@unchecked Sendable` is justified by construction: `key`, `url`,
///   `title`, `index`, `mediaType` and `downloadTask` are all `let`, and the two
///   genuinely mutable members — the resolved duration and the Combine
///   subscription — are lock-guarded.
final class OverdriveTrack: Track, @unchecked Sendable {
  let key: String
  let downloadTask: (any DownloadTask)?
  let title: String?
  let index: Int
  let url: URL
  var urls: [URL]? { [url] }
  let mediaType: TrackMediaType

  /// Lock-guarded. Previously a bare `var` written from an AVFoundation
  /// callback (hopped to main) and read by `duration` from any thread — an
  /// unsynchronized read/write of a `TimeInterval`.
  private let _duration = LockIsolated<TimeInterval>(0)

  /// Lock-guarded, and used to make duration resolution fire at most once.
  private let durationLoad = LockIsolated<DurationLoadState>(.idle)

  private enum DurationLoadState {
    case idle
    case loading
    case resolved
  }

  /// Combine subscriptions, guarded by a raw lock rather than `LockIsolated`:
  /// `AnyCancellable` is not `Sendable`, so it cannot be a `LockIsolated`
  /// payload. The class's `@unchecked Sendable` covers this because the set is
  /// only ever touched under `cancellablesLock`.
  private let cancellablesLock = NSLock()
  private var cancellables = Set<AnyCancellable>()

  /// - Important: reading this is cheap and side-effect-free once the duration
  ///   has been resolved (or is being resolved).
  ///
  ///   It did not used to be. Every read while the duration was still 0 kicked
  ///   off a fresh `AVURLAsset` load, and `Tracks.totalDuration` reduces
  ///   `duration` over every track on each UI refresh — so an Overdrive title
  ///   whose duration had not resolved yet spawned asset loads continuously for
  ///   as long as it was on screen, burning CPU and battery. The load is now
  ///   attempted once and the state machine refuses re-entry.
  var duration: TimeInterval {
    let current = _duration.value
    guard current <= 0 else {
      return current
    }
    requestDurationUpdate()
    return _duration.value
  }

  required init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    token _: String? = nil,
    key _: String?
  ) throws {
    guard let urlString, let url = URL(string: urlString) else {
      throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
    }

    let trackKey = "urn:org.thepalaceproject:readingOrder:\(String(describing: index))"
    key = trackKey
    self.url = url
    self.title = title
    self.index = index
    mediaType = manifest.trackMediaType

    let initialDuration = duration > 0 ? duration : 0
    _duration.value = initialDuration
    if initialDuration > 0 {
      // The manifest already told us the duration; no asset load is warranted.
      durationLoad.value = .resolved
    }

    let task = OverdriveDownloadTask(key: trackKey, url: url, mediaType: mediaType, bookID: audiobookID)
    downloadTask = task

    let subscription = task.statePublisher
      .sink(receiveValue: { [weak self] state in
        guard let self else {
          return
        }
        switch state {
        case .completed:
          // A finished download supersedes whatever the manifest claimed, so
          // allow exactly one re-resolution from the real file.
          self.durationLoad.value = .idle
          self.updateDuration()
        default:
          break
        }
      })
    cancellablesLock.withLock { _ = cancellables.insert(subscription) }
  }

  func updateDuration() {
    // Claim the load atomically. Without this, every `duration` read before
    // resolution started another `AVURLAsset` load.
    let mayLoad = durationLoad.withValue { state -> Bool in
      guard case .idle = state else { return false }
      state = .loading
      return true
    }
    guard mayLoad else {
      return
    }

    guard let localURL = (downloadTask as? OverdriveDownloadTask)?.localDirectory() else {
      durationLoad.value = .idle
      return
    }

    let asset = AVURLAsset(url: localURL)
    Task { [weak self] in
      guard let self else {
        return
      }
      do {
        // Replaces the iOS 16-deprecated `loadValuesAsynchronously` +
        // `statusOfValue` + `asset.duration` trio.
        let loaded = try await asset.load(.duration)
        self._duration.value = CMTimeGetSeconds(loaded)
        self.durationLoad.value = .resolved
      } catch {
        // Allow a later attempt (e.g. after the download completes) rather than
        // latching a failure forever.
        self.durationLoad.value = .idle
        ATLog(.warn, "OverdriveTrack: could not load duration for \(self.key)", error: error as NSError)
      }
    }
  }

  func requestDurationUpdate() {
    updateDuration()
  }
}
