//
//  AudiobookNetworkService.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/22/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Combine
import UIKit

// MARK: - DownloadState

public enum DownloadState {
  case progress(track: any Track, progress: Float)
  case completed(track: any Track)
  case deleted(track: any Track)
  case error(track: any Track, error: Error?)
  case overallProgress(progress: Float)
  case downloadComplete
}

// MARK: - AudiobookNetworkService

/// The protocol for managing the download of chapters. Implementers of
/// this protocol should not be concerned with the details of how
/// the downloads happen or any caching.
///
/// The purpose of an AudiobookNetworkService is to manage the download
/// tasks and tie them back to their spine elements
/// for delegates to consume.
public protocol AudiobookNetworkService: AnyObject {
  var tracks: [any Track] { get }
  var downloadStatePublisher: PassthroughSubject<DownloadState, Never> { get }

  /// Implementers of this should attempt to download all
  /// spine elements in a serial order. Once the
  /// implementer has begun requesting files, calling this
  /// again should not fire more requests. If no request is
  /// in progress, fetch should always start at the first
  /// spine element.
  ///
  /// Implementations of this should be non-blocking.
  /// Updates for the status of each download task will
  /// come through downloadStatePublisher.
  func fetch()

  /// Implementations of this should be non-blocking.
  /// Updates for the status of each download task will
  /// come through downloadStatePublisher.
  func fetchUndownloadedTracks()

  /// Implmenters of this should attempt to delete all
  /// spine elements.
  ///
  /// Implementations of this should be non-blocking.
  /// Updates for the status of each download task will
  /// come through delegate methods.
  func deleteAll()
  func cleanup()
}

// MARK: - DefaultAudiobookNetworkService

/// - Note: This type is deliberately **not** declared `Sendable`, and the
///   closure-capture warnings that remain on it are load-bearing rather than
///   noise. Its own storage is fully accounted for — every stored property below
///   is either a `let` or guarded (by `queue`, with `.barrier` on every write, or
///   by a lock) — but three of those `let`s point at referents that are
///   themselves unsynchronized mutable state:
///
///   * `tracks` — `Track` is a non-`Sendable` class protocol whose conformers
///     (`OpenAccessTrack`, `LCPTrack`, `OverdriveTrack`, `FindawayTrack`) are
///     non-final classes of plain `public var` storage.
///   * `decryptor` — `DRMDecryptor` is an `@objc` protocol implemented app-side.
///   * `reachability` — `Reachability` mutates `isConnected` and `retriesCounter`
///     from `NWPathMonitor`'s queue and from main with no synchronization.
///
///   Declaring `@unchecked Sendable` here would assert that those referents are
///   safe to hand across isolation domains, which this file cannot prove; the
///   claim would silence the diagnostics that currently point at the real
///   hazard. Once the `Track` conformers and `Reachability` are migrated the
///   conformance becomes a one-line change, and the list above is its checklist.
public final class DefaultAudiobookNetworkService: AudiobookNetworkService {
  /// Assigned once and only read (and `send`-ed to) afterwards — the protocol
  /// exposes it get-only — so `let` proves the invariant for free.
  public let downloadStatePublisher = PassthroughSubject<DownloadState, Never>()
  public let tracks: [any Track]

  /// Guarded by `cancellablesLock` rather than by `queue`, for two reasons:
  /// `deinit` calls `cleanupSubscriptions()`, and `deinit` can run *on* `queue`
  /// (the barrier blocks in `updateProgress`/`updateDownloadStatus` capture
  /// `self` strongly, so the final release may happen inside one of them) — a
  /// `queue.sync(flags: .barrier)` from there would deadlock. And `LockIsolated`
  /// is unavailable because it requires a `Sendable` payload, which
  /// `AnyCancellable` is not.
  private let cancellablesLock = NSLock()
  private var cancellables: Set<AnyCancellable> = []

  /// `progressDictionary`, `downloadStatus`, `activeDownloadIndices` and
  /// `lastPublishedOverallProgress` are all guarded by `queue`: reads go through
  /// `queue.sync`, and **every** write goes through a `.barrier` block. `queue`
  /// is `.concurrent`, so a non-barrier write is not serialized against anything
  /// — the barrier is what makes this a lock rather than decoration.
  private var progressDictionary: [String: Float] = [:]
  private var downloadStatus: [String: DownloadTaskState] = [:]
  private let queue = DispatchQueue(label: "com.palace.downloadProgressQueue", attributes: .concurrent)
  private var activeDownloadIndices: Set<Int> = []
  private let maxConcurrentTrackDownloads = 3
  public let decryptor: DRMDecryptor?

  /// When `true`, track downloads are only started on Wi-Fi connections.
  ///
  /// Lock-guarded: the app writes this from the main thread just after
  /// construction while `fillDownloadSlots` reads it from a `queue` barrier block
  /// on a background thread. `Bool` is not exempt from the rule — an
  /// unsynchronized concurrent read/write is undefined behaviour regardless of
  /// width. The public name stays a settable `var` so call sites are untouched.
  private let _downloadOnlyOnWiFi = LockIsolated(false)
  public var downloadOnlyOnWiFi: Bool {
    get { _downloadOnlyOnWiFi.value }
    set { _downloadOnlyOnWiFi.value = newValue }
  }

  private let reachability = Reachability()

  /// Last overall progress published, used to keep the bar monotonic and to
  /// avoid redundant main-thread dispatches.
  ///
  /// Deliberately guarded by its own lock rather than by `queue`. The gate is a
  /// read-modify-write, so it needs mutual exclusion — but taking that
  /// exclusion on `queue` would mean a barrier, and both callers run on main,
  /// so main would wait out the queue's backlog (which includes per-track file
  /// I/O) on every progress tick. A dedicated lock is atomic and uncoupled.
  private let publishGate = LockIsolated<Float>(-1)

  public init(tracks: [any Track], decryptor: DRMDecryptor? = nil) {
    self.tracks = tracks
    self.decryptor = decryptor
    reachability.startMonitoring()
    setupDownloadTasks()
    initializeProgressFromCurrentState()
  }
  
  /// Initialize progress dictionary based on current download state of all tracks.
  /// This ensures correct progress is shown when reopening an audiobook mid-download.
  private func initializeProgressFromCurrentState() {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      for track in self.tracks {
        if let downloadTask = track.downloadTask {
          // Read current progress (which checks actual file status for lazy-initialized tasks)
          let progress = downloadTask.downloadProgress
          self.progressDictionary[track.key] = progress
        }
      }
      // Publish initial overall progress on main queue
      DispatchQueue.main.async {
        self.updateOverallProgress()
      }
    }
  }

  public func fetch() {
    fillDownloadSlots(startingFrom: 0)
  }

  public func fetchUndownloadedTracks() {
    // Retry any tracks that need it, then fill remaining slots
    for (index, track) in tracks.enumerated() {
      if track.downloadTask?.needsRetry ?? false {
        startDownload(at: index)
      }
    }
    // Fill any remaining download slots with the next undownloaded tracks
    fillDownloadSlots(startingFrom: 0)
  }

  public func deleteAll() {
    tracks.forEach { $0.downloadTask?.delete() }
  }

  private func setupDownloadTasks() {
    // Collect locally, then merge under the lock: a subscription can start
    // delivering on a background thread as soon as it is made (a background
    // `URLSession` may already be mid-download), so the store must not be a
    // series of unguarded mutations of the shared set.
    var collected: Set<AnyCancellable> = []
    tracks.forEach { track in
      guard let downloadTask = track.downloadTask else {
        return
      }
      downloadTask.statePublisher
        .sink { [weak self] state in
          guard let self = self else {
            return
          }
          handleDownloadState(state, for: track)
        }
        .store(in: &collected)
    }
    cancellablesLock.withLock { cancellables.formUnion(collected) }
  }

  private func handleDownloadState(_ state: DownloadTaskState, for track: any Track) {
    switch state {
    case let .progress(progress):
      updateProgress(progress, for: track)
    case .completed:
      updateProgress(1.0, for: track)
      downloadStatePublisher.send(.completed(track: track))
      updateDownloadStatus(for: track, state: .completed)
      releaseDownloadSlot(for: track)
      fillDownloadSlots(startingFrom: 0)
    case let .error(error):
      downloadStatePublisher.send(.error(track: track, error: error))
      updateDownloadStatus(for: track, state: .error(error))
      releaseDownloadSlot(for: track)
      fillDownloadSlots(startingFrom: 0)
    case .deleted:
      downloadStatePublisher.send(.deleted(track: track))
    }

    checkIfAllTasksFinished()
  }

  private func updateProgress(_ progress: Float, for track: any Track) {
    queue.async(flags: .barrier) {
      let currentProgress = self.progressDictionary[track.key] ?? 0.0
      // Enforce monotonic progress: never report a value lower than what we've already seen.
      // URLSession can report backwards progress on retries or when expectedBytes changes,
      // and download tasks reset to 0.0 on cancel/error. Clamping here prevents the
      // progress bar from sliding backwards in the UI.
      let clampedProgress = max(currentProgress, progress)
      self.progressDictionary[track.key] = clampedProgress
      DispatchQueue.main.async {
        self.updateOverallProgress()
        self.downloadStatePublisher.send(.progress(track: track, progress: clampedProgress))
      }
    }
  }

  private func updateOverallProgress() {
    // Snapshot the inputs under a plain concurrent read. This does NOT need a
    // barrier: it only reads, and the read-modify-write that genuinely needs
    // atomicity is the `lastPublishedOverallProgress` gate below, which has its
    // own lock.
    //
    // A `.barrier` sync here would be atomic but costly in the wrong place:
    // both callers run on main, and a barrier waits out the whole queue
    // backlog — including `fillDownloadSlots`, whose barrier block reads
    // `downloadTask?.downloadProgress` per track and therefore does file-system
    // work in the LCP case. That would park the main thread behind disk I/O on
    // every progress tick.
    let snapshot: (values: [Float], trackCount: Int)? = queue.sync {
      guard !progressDictionary.isEmpty else {
        return nil
      }
      return (Array(progressDictionary.values), tracks.count)
    }
    guard let snapshot, snapshot.trackCount > 0 else {
      return
    }

    let overallProgress = snapshot.values.reduce(0, +) / Float(snapshot.trackCount)

    // Compare-and-publish must be one atomic step, or two concurrent ticks can
    // both pass the monotonic guard and both publish. Its own lock keeps that
    // atomic without coupling it to the download-bookkeeping queue.
    let shouldPublish = publishGate.withValue { lastPublished -> Bool in
      // Enforce monotonic overall progress: never publish a value lower than
      // what we've already published. This prevents the overall progress bar
      // from jittering backwards when individual track progress fluctuates.
      guard overallProgress >= lastPublished else { return false }

      // Only dispatch to main thread if progress changed meaningfully (>0.5%)
      // This prevents excessive main-thread work during large audiobook downloads
      guard overallProgress - lastPublished > 0.005 || overallProgress >= 1.0 else { return false }

      lastPublished = overallProgress
      return true
    }
    guard shouldPublish else {
      return
    }

    DispatchQueue.main.async {
      self.downloadStatePublisher.send(.overallProgress(progress: overallProgress))
    }
  }

  private func updateDownloadStatus(for track: any Track, state: DownloadTaskState) {
    // Read the key on the caller's thread so the barrier block carries a
    // `String` across the boundary instead of the whole non-`Sendable` track.
    let key = track.key
    queue.async(flags: .barrier) {
      self.downloadStatus[key] = state
    }
  }

  private func checkIfAllTasksFinished() {
    queue.sync {
      let allFinished = tracks.allSatisfy { track in
        if let state = downloadStatus[track.key] {
          switch state {
          case .completed, .error:
            return true
          default:
            return false
          }
        }
        return false
      }

      if allFinished {
        DispatchQueue.main.async {
          self.downloadStatePublisher.send(.downloadComplete)
        }
      }
    }
  }

  // MARK: - Concurrent Download Slot Management
  
  /// Fills available download slots starting from the given index.
  /// Downloads up to `maxConcurrentTrackDownloads` tracks simultaneously.
  private func fillDownloadSlots(startingFrom searchStart: Int) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self else { return }

      if self.downloadOnlyOnWiFi && !self.reachability.isOnWiFi {
        ATLog(.info, "🎵 [NetworkService] Download blocked — Wi-Fi only mode and device is not on Wi-Fi")
        return
      }
      
      var index = searchStart
      while index < tracks.count, activeDownloadIndices.count < maxConcurrentTrackDownloads {
        let track = tracks[index]
        let isAlreadyActive = activeDownloadIndices.contains(index)
        
        // Skip tracks with no download task — allocating a slot for these
        // would permanently block it since no progress/completion events will fire.
        guard track.downloadTask != nil else {
          index += 1
          continue
        }
        
        let isCompleted: Bool = {
          if let status = self.downloadStatus[track.key] {
            switch status {
            case .completed: return true
            default: return false
            }
          }
          return false
        }()
        let progress = track.downloadTask?.downloadProgress ?? 0.0

        // Skip tracks that received 403 Forbidden — retrying is pointless
        // and hammers the content server.
        let isForbidden = (track.downloadTask as? OpenAccessDownloadTask)?.isForbidden ?? false

        if !isAlreadyActive && !isCompleted && !isForbidden && progress < 1.0 {
          activeDownloadIndices.insert(index)
          let capturedIndex = index
          // Dispatch the actual download start outside the barrier to avoid holding the lock
          DispatchQueue.main.async { [weak self] in
            self?.startDownload(at: capturedIndex)
          }
        }
        index += 1
      }
    }
  }
  
  /// Releases a download slot when a track completes or errors.
  private func releaseDownloadSlot(for track: any Track) {
    // Read the key on the caller's thread so the barrier block carries a
    // `String` across the boundary instead of the whole non-`Sendable` track.
    let key = track.key
    queue.async(flags: .barrier) { [weak self] in
      guard let self else { return }
      if let index = tracks.firstIndex(where: { $0.key == key }) {
        activeDownloadIndices.remove(index)
      }
    }
  }

  private func startDownload(at index: Int) {
    guard index < tracks.count else { return }
    let track = tracks[index]

    // Safety net: if downloadTask is nil, release the slot immediately
    // to prevent it from being permanently occupied.
    guard track.downloadTask != nil else {
      ATLog(.warn, "🎵 [NetworkService] Track \(track.key) has no download task — releasing slot")
      releaseDownloadSlot(for: track)
      fillDownloadSlots(startingFrom: index + 1)
      return
    }

    if let lcpTask = track.downloadTask as? LCPDownloadTask, let decryptedUrls = lcpTask.decryptedUrls,
       let decryptor = decryptor
    {
      startLCPDecryption(task: lcpTask, trackIndex: index, originalUrls: lcpTask.urls, decryptedUrls: decryptedUrls, decryptor: decryptor)
      return
    }

    if track.downloadTask?.downloadProgress ?? 0.0 < 1.0 {
      track.downloadTask?.fetch()
    } else {
      // Already downloaded — release slot and fill next
      releaseDownloadSlot(for: track)
      fillDownloadSlots(startingFrom: index + 1)
    }
  }

  /// Thread-safe LCP decryption using an atomic counter to prevent data races
  /// on the `completed` variable when multiple decrypt callbacks fire concurrently.
  private func startLCPDecryption(
    task: LCPDownloadTask,
    trackIndex: Int,
    originalUrls: [URL],
    decryptedUrls: [URL],
    decryptor: DRMDecryptor
  ) {
    let fileManager = FileManager.default
    let track = tracks[trackIndex]

    let missingPairs: [(URL, URL)] = zip(originalUrls, decryptedUrls)
      .filter { _, dst in !fileManager.fileExists(atPath: dst.path) }
    
    if missingPairs.isEmpty {
      task.downloadProgress = 1.0
      updateProgress(1.0, for: track)
      downloadStatePublisher.send(.completed(track: track))
      updateDownloadStatus(for: track, state: .completed)
      releaseDownloadSlot(for: track)
      fillDownloadSlots(startingFrom: trackIndex + 1)
      return
    }

    let total = missingPairs.count
    // Thread-safe counters for concurrent decryption callbacks: one `decrypt` is
    // in flight per missing pair and the decryptor invokes each completion on a
    // queue of its own choosing, so both of these are touched concurrently.
    //
    // `LockIsolated` replaces the hand-rolled `NSLock` + captured local `var`s.
    // The discipline is the same — this is a 1:1 translation, deliberately
    // including the two-phase test-then-set on `hasErrored` — but the compiler
    // can see it, and a mutable local captured by an escaping closure becomes a
    // hard error the moment `DRMDecryptor`'s completion is made `@Sendable`.
    let completedCount = LockIsolated(0)
    let hasErrored = LockIsolated(false)

    for (src, dst) in missingPairs {
      decryptor.decrypt(url: src, to: dst) { [weak self] error in
        guard let self else { return }

        // Bail early if we already reported an error for this track
        guard !hasErrored.value else { return }

        if let error {
          hasErrored.value = true
          downloadStatePublisher.send(.error(track: track, error: error))
          updateDownloadStatus(for: track, state: .error(error))
          releaseDownloadSlot(for: track)
          fillDownloadSlots(startingFrom: trackIndex + 1)
        } else {
          let newCount = completedCount.withValue { count -> Int in
            count += 1
            return count
          }

          let progress = Float(newCount) / Float(total)
          task.downloadProgress = progress
          updateProgress(progress, for: track)
          
          if newCount == total {
            downloadStatePublisher.send(.completed(track: track))
            updateDownloadStatus(for: track, state: .completed)
            releaseDownloadSlot(for: track)
            fillDownloadSlots(startingFrom: trackIndex + 1)
          }
        }
      }
    }
  }

  deinit {
    // Don't cancel downloads on deinit - they should continue in background
    // Only clean up Combine subscriptions
    reachability.stopMonitoring()
    cleanupSubscriptions()
  }

  /// Cleans up Combine subscriptions without cancelling downloads.
  /// Downloads continue in the background via URLSession background sessions.
  public func cleanupSubscriptions() {
    // Take the subscriptions out under the lock, then cancel outside it:
    // `cancel()` runs foreign Combine code, which must not run while a lock is
    // held. Nothing else reads `cancellables`, so draining before cancelling
    // rather than after is not observable.
    let subscriptions = cancellablesLock.withLock { () -> Set<AnyCancellable> in
      let current = cancellables
      cancellables.removeAll()
      return current
    }
    subscriptions.forEach { $0.cancel() }
    ATLog(.debug, "🎵 [NetworkService] Cleaned up subscriptions, downloads continue in background")
  }
  
  /// Cleans up subscriptions only. Downloads continue via background URLSession.
  /// Use `cancelAllDownloads()` to explicitly cancel downloads.
  public func cleanup() {
    cleanupSubscriptions()
  }
  
  /// Explicitly cancels all active downloads.
  /// Only call this when the user explicitly wants to cancel downloads,
  /// NOT when the audiobook player is simply closed.
  public func cancelAllDownloads() {
    ATLog(.info, "🎵 [NetworkService] Explicitly cancelling all downloads")
    tracks.forEach { track in
      if track.downloadTask is LCPDownloadTask {
        ATLog(.debug, "🎵 [NetworkService] Keeping LCP download task running for track: \(track.key)")
      } else {
        track.downloadTask?.cancel()
        ATLog(.debug, "🎵 [NetworkService] Cancelled download for track: \(track.key)")
      }
    }
  }
  
  /// Cancels download for a specific track.
  /// - Parameter trackKey: The key of the track to cancel
  public func cancelDownload(forTrackKey trackKey: String) {
    guard let track = tracks.first(where: { $0.key == trackKey }) else {
      ATLog(.warn, "🎵 [NetworkService] Track not found for cancellation: \(trackKey)")
      return
    }
    
    if track.downloadTask is LCPDownloadTask {
      ATLog(.debug, "🎵 [NetworkService] Cannot cancel LCP download for track: \(trackKey)")
      return
    }
    
    track.downloadTask?.cancel()
    ATLog(.info, "🎵 [NetworkService] Cancelled download for track: \(trackKey)")
  }
}
