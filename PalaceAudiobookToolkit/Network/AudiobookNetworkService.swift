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

public final class DefaultAudiobookNetworkService: AudiobookNetworkService {
  public var downloadStatePublisher = PassthroughSubject<DownloadState, Never>()
  public let tracks: [any Track]
  private var cancellables: Set<AnyCancellable> = []
  private var progressDictionary: [String: Float] = [:]
  private var downloadStatus: [String: DownloadTaskState] = [:]
  private let queue = DispatchQueue(label: "com.palace.downloadProgressQueue", attributes: .concurrent)
  private var activeDownloadIndices: Set<Int> = []
  private let maxConcurrentTrackDownloads = 3
  public let decryptor: DRMDecryptor?
  
  /// Cached overall progress to avoid redundant main-thread dispatches
  private var lastPublishedOverallProgress: Float = -1

  public init(tracks: [any Track], decryptor: DRMDecryptor? = nil) {
    self.tracks = tracks
    self.decryptor = decryptor
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
        .store(in: &self.cancellables)
    }
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
    queue.sync {
      guard !progressDictionary.isEmpty else {
        return
      }

      let totalProgress = progressDictionary.values.reduce(0, +)
      let overallProgress = totalProgress / Float(tracks.count)
      
      // Enforce monotonic overall progress: never publish a value lower than
      // what we've already published. This prevents the overall progress bar
      // from jittering backwards when individual track progress fluctuates.
      guard overallProgress >= lastPublishedOverallProgress else { return }
      
      // Only dispatch to main thread if progress changed meaningfully (>0.5%)
      // This prevents excessive main-thread work during large audiobook downloads
      let delta = overallProgress - lastPublishedOverallProgress
      guard delta > 0.005 || overallProgress >= 1.0 else { return }
      lastPublishedOverallProgress = overallProgress
      
      DispatchQueue.main.async {
        self.downloadStatePublisher.send(.overallProgress(progress: overallProgress))
      }
    }
  }

  private func updateDownloadStatus(for track: any Track, state: DownloadTaskState) {
    queue.async(flags: .barrier) {
      self.downloadStatus[track.key] = state
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
        
        if !isAlreadyActive && !isCompleted && progress < 1.0 {
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
    queue.async(flags: .barrier) { [weak self] in
      guard let self else { return }
      if let index = tracks.firstIndex(where: { $0.key == track.key }) {
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
    // Thread-safe counter for concurrent decryption callbacks.
    // Using NSLock instead of OSAllocatedUnfairLock to support iOS 13+ deployment target.
    let lock = NSLock()
    var completedCount = 0
    var hasErrored = false

    for (src, dst) in missingPairs {
      decryptor.decrypt(url: src, to: dst) { [weak self] error in
        guard let self else { return }
        
        lock.lock()
        // Bail early if we already reported an error for this track
        let alreadyErrored = hasErrored
        lock.unlock()
        guard !alreadyErrored else { return }
        
        if let error {
          lock.lock()
          hasErrored = true
          lock.unlock()
          downloadStatePublisher.send(.error(track: track, error: error))
          updateDownloadStatus(for: track, state: .error(error))
          releaseDownloadSlot(for: track)
          fillDownloadSlots(startingFrom: trackIndex + 1)
        } else {
          lock.lock()
          completedCount += 1
          let newCount = completedCount
          lock.unlock()
          
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
    cleanupSubscriptions()
  }

  /// Cleans up Combine subscriptions without cancelling downloads.
  /// Downloads continue in the background via URLSession background sessions.
  public func cleanupSubscriptions() {
    cancellables.forEach { $0.cancel() }
    cancellables.removeAll()
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
