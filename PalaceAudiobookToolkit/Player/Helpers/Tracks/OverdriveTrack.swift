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

/// Reads the duration of a finished media file.
///
/// Injected rather than called directly so the state machine below can be
/// driven without AVFoundation: a test can make a load hang, throw, or return
/// `NaN` on demand, and can count how many times it was asked. Every defect
/// this file has produced was in the state machine, not in AVFoundation, and
/// none of them were reachable while the loader was hard-wired.
typealias TrackDurationLoader = @Sendable (URL) async throws -> TimeInterval

/// - Note: `@unchecked Sendable` is justified by construction: `key`, `url`,
///   `title`, `index`, `mediaType`, `downloadTask` and `loadDurationFromFile`
///   are all `let`, and the two genuinely mutable members — the resolved
///   duration and the Combine subscription — are lock-guarded.
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

  /// Lock-guarded. Bounds how often duration resolution may be attempted.
  ///
  /// - Important: every mutation of this value goes through one of the four
  ///   transition helpers below (`claimDurationLoad`, `completeDurationLoad`,
  ///   `recordDurationLoadFailure`, `noteDownloadCompleted`). Writing
  ///   `durationLoad.value = …` from anywhere else reintroduces the class of
  ///   defect this machine exists to prevent — that is exactly how the
  ///   download-completion sink came to clobber a load already in flight.
  private let durationLoad = LockIsolated<DurationLoadState>(.idle)

  private enum DurationLoadState {
    case idle
    /// A load is in flight.
    ///
    /// `priorFailures` is carried THROUGH the claim. It used to be discarded
    /// here — the claim matched `.failed(attempts)` and then wrote a plain
    /// `.loading`, so the failure handler always saw `.loading`, always took
    /// its "first failure" branch, and always wrote back `attempts: 1`. The
    /// count could never reach the limit, so the bound below never bound
    /// anything and an unreadable file retried forever.
    ///
    /// `supersededByCompletion` records that the download finished while this
    /// load was already reading the file. See `noteDownloadCompleted()`.
    case loading(priorFailures: Int, supersededByCompletion: Bool)
    case resolved
    /// Bounded so a file that cannot be read (truncated, wrong codec) does not
    /// let every subsequent `duration` read start another load forever.
    case failed(attempts: Int)
  }

  private static let maxDurationLoadAttempts = 3

  /// Builds an `AVURLAsset` and reads its duration. The production default for
  /// `loadDurationFromFile`.
  static let assetDurationLoader: TrackDurationLoader = { url in
    // Replaces the iOS 16-deprecated `loadValuesAsynchronously` +
    // `statusOfValue` + `asset.duration` trio.
    let loaded = try await AVURLAsset(url: url).load(.duration)
    return CMTimeGetSeconds(loaded)
  }

  private let loadDurationFromFile: TrackDurationLoader

  /// Combine subscriptions, guarded by a raw lock rather than `LockIsolated`:
  /// `AnyCancellable` is not `Sendable`, so it cannot be a `LockIsolated`
  /// payload. The class's `@unchecked Sendable` covers this because the set is
  /// only ever touched under `cancellablesLock`.
  private let cancellablesLock = NSLock()
  private var cancellables = Set<AnyCancellable>()

  /// - Important: this is NOT free while the duration is still unresolved.
  ///   Each such read stats the file (see `updateDuration()`), and
  ///   `Tracks.totalDuration` reduces `duration` over every track on each UI
  ///   refresh. What it no longer does is start an unbounded number of asset
  ///   loads: at most `maxDurationLoadAttempts` failed attempts, plus one
  ///   further attempt each time the download reports completion. Once the
  ///   duration resolves the read is a single lock acquisition.
  var duration: TimeInterval {
    let current = _duration.value
    guard current <= 0 else {
      return current
    }
    requestDurationUpdate()
    return _duration.value
  }

  init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    key _: String?,
    durationLoader: @escaping TrackDurationLoader
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
    loadDurationFromFile = durationLoader

    let initialDuration = duration > 0 ? duration : 0
    _duration.value = initialDuration
    if initialDuration > 0 {
      // The manifest already told us the duration; no asset load is warranted.
      // This is the one write outside the transition helpers, and it is sound
      // because nothing else can observe the machine before `init` returns.
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
          // A finished download supersedes whatever the manifest claimed, and
          // supersedes any value read from the partially-written file.
          self.noteDownloadCompleted()
          self.updateDuration()
        default:
          break
        }
      })
    cancellablesLock.withLock { _ = cancellables.insert(subscription) }
  }

  required convenience init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    token _: String? = nil,
    key: String?
  ) throws {
    try self.init(
      manifest: manifest,
      urlString: urlString,
      audiobookID: audiobookID,
      title: title,
      duration: duration,
      index: index,
      key: key,
      durationLoader: OverdriveTrack.assetDurationLoader
    )
  }

  func updateDuration() {
    // Check the file BEFORE claiming the load. `localDirectory()` returns a
    // path whether or not anything exists there, so without this the entire
    // pre-download window behaves exactly like the bug this is meant to fix:
    // every read claims, builds an `AVURLAsset` on a nonexistent path, throws,
    // releases the claim, and the next read claims again. Bounding concurrency
    // is not the same as bounding the work. When the file does land, the
    // download-completion sink drives resolution.
    //
    // Note what this check does NOT establish: that the file is COMPLETE.
    // `MediaProcessor.optimizeQTFile` — which the shared download delegate
    // routes to via `verifyDownloadAndMove` when a file needs optimizing —
    // creates a zero-byte file at the FINAL url and then writes it
    // progressively, so `fileExists` passes throughout. A load started in that
    // window reads a partial file and can come back with a short-but-finite
    // duration. `noteDownloadCompleted()` is what stops that answer from
    // becoming permanent.
    guard let localURL = (downloadTask as? OverdriveDownloadTask)?.localDirectory(),
          FileManager.default.fileExists(atPath: localURL.path)
    else {
      return
    }

    guard claimDurationLoad() else {
      return
    }

    Task { [weak self] in
      guard let self else {
        return
      }
      do {
        let seconds = try await self.loadDurationFromFile(localURL)
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
        self.completeDurationLoad(seconds: seconds)
      } catch {
        self.recordDurationLoadFailure()
        ATLog(.warn, "OverdriveTrack: could not load duration for \(self.key)", error: error as NSError)
      }
    }
  }

  // MARK: - Duration-load transitions
  //
  // The only four places `durationLoad` is written after `init`.

  /// Claims the right to run one load, carrying the accumulated failure count
  /// forward so the retry bound can actually count.
  private func claimDurationLoad() -> Bool {
    durationLoad.withValue { state -> Bool in
      switch state {
      case .idle:
        state = .loading(priorFailures: 0, supersededByCompletion: false)
        return true
      case let .failed(attempts) where attempts < Self.maxDurationLoadAttempts:
        state = .loading(priorFailures: attempts, supersededByCompletion: false)
        return true
      case .loading, .resolved, .failed:
        return false
      }
    }
  }

  /// Publishes a usable duration and closes the machine — unless the download
  /// completed while this load was running, in which case the value may have
  /// come from a partially-written file and the machine reopens so the finished
  /// file can be read. Publishing either way is deliberate: a short duration is
  /// better than zero for the moment it takes the re-read to land.
  private func completeDurationLoad(seconds: TimeInterval) {
    // Value and terminal state are set in one critical section so a concurrent
    // transition cannot interleave between them.
    let wasSuperseded = durationLoad.withValue { state -> Bool in
      _duration.value = seconds
      if case .loading(_, supersededByCompletion: true) = state {
        state = .idle
        return true
      }
      state = .resolved
      return false
    }

    if wasSuperseded {
      // Reopening the machine is not enough on its own: the getter short-
      // circuits as soon as the duration is non-zero, so nothing would ever ask
      // again and the value read from the partial file would stand. Read the
      // finished file now. Called outside the critical section — `updateDuration`
      // takes the same lock.
      updateDuration()
    }
  }

  private func recordDurationLoadFailure() {
    durationLoad.withValue { state in
      switch state {
      case let .loading(priorFailures, _):
        state = .failed(attempts: priorFailures + 1)
      case let .failed(attempts):
        state = .failed(attempts: attempts + 1)
      case .idle, .resolved:
        state = .failed(attempts: 1)
      }
    }
  }

  /// Permits one further resolution now that the real file is on disk and
  /// complete, and re-arms the retry budget (the earlier failures were against
  /// a file that was still being written).
  ///
  /// Deliberately does NOT cancel or reset a load already in flight — its write
  /// order against a replacement load would be undefined. Instead it marks the
  /// in-flight load's result as superseded, so `completeDurationLoad` reopens
  /// the machine rather than latching a value that may have come from a partial
  /// file. Previously this method existed but had no callers: the sink wrote
  /// `.idle` directly, clobbering `.loading`, which is the very thing this
  /// comment says must not happen.
  private func noteDownloadCompleted() {
    durationLoad.withValue { state in
      if case let .loading(priorFailures, _) = state {
        state = .loading(priorFailures: priorFailures, supersededByCompletion: true)
      } else {
        state = .idle
      }
    }
  }

  func requestDurationUpdate() {
    updateDuration()
  }
}
