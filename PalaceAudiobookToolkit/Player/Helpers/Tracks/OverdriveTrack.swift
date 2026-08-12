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
    /// Bounded so a file that cannot be read (truncated, wrong codec) does not
    /// let every subsequent `duration` read start another load forever.
    case failed(attempts: Int)
  }

  private static let maxDurationLoadAttempts = 3

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
    // Check the file BEFORE claiming the load. `localDirectory()` returns a
    // path whether or not anything exists there, so without this the entire
    // pre-download window behaves exactly like the bug this is meant to fix:
    // every read claims, builds an `AVURLAsset` on a nonexistent path, throws,
    // releases the claim, and the next read claims again. Bounding concurrency
    // is not the same as bounding the work. When the file does land, the
    // download-completion sink drives resolution.
    guard let localURL = (downloadTask as? OverdriveDownloadTask)?.localDirectory(),
          FileManager.default.fileExists(atPath: localURL.path)
    else {
      return
    }

    // Claim the load atomically, and only from a state that permits one.
    let mayLoad = durationLoad.withValue { state -> Bool in
      switch state {
      case .idle:
        state = .loading
        return true
      case let .failed(attempts) where attempts < Self.maxDurationLoadAttempts:
        state = .loading
        return true
      case .loading, .resolved, .failed:
        return false
      }
    }
    guard mayLoad else {
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
        let seconds = CMTimeGetSeconds(loaded)
        // A load can SUCCEED and still yield nothing usable — `CMTime`
        // `.indefinite` gives NaN, and a zero-length or still-being-written
        // file gives 0. Marking that `.resolved` would latch the track at
        // duration 0 permanently: the getter sees `<= 0`, asks again, and the
        // state machine refuses. The pre-existing code self-healed because it
        // retried on every read; that recovery must not be traded away for the
        // reload-storm fix. Treat it as a bounded failure instead.
        guard seconds.isFinite, seconds > 0 else {
          self.recordDurationLoadFailure()
          ATLog(.warn, "OverdriveTrack: duration load produced \(seconds) for \(self.key)")
          return
        }
        // Publish the value and the terminal state in one critical section so a
        // concurrent reset cannot interleave between them.
        self.durationLoad.withValue { state in
          self._duration.value = seconds
          state = .resolved
        }
      } catch {
        self.recordDurationLoadFailure()
        ATLog(.warn, "OverdriveTrack: could not load duration for \(self.key)", error: error as NSError)
      }
    }
  }

  private func recordDurationLoadFailure() {
    durationLoad.withValue { state in
      if case let .failed(attempts) = state {
        state = .failed(attempts: attempts + 1)
      } else {
        state = .failed(attempts: 1)
      }
    }
  }

  /// Permits exactly one further resolution attempt, used when a download
  /// completes and the real file supersedes whatever the manifest claimed.
  ///
  /// Deliberately does NOT disturb a load already in flight: that load is
  /// reading the same finished file and will publish the same answer, and
  /// resetting under it would allow a second concurrent load whose write order
  /// against the first is undefined.
  private func allowOneMoreResolution() {
    durationLoad.withValue { state in
      if case .loading = state {
        return
      }
      state = .idle
    }
  }

  func requestDurationUpdate() {
    updateDuration()
  }
}
