//
//  AudiobookPlaybackController.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 12/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Combine
import MediaPlayer
import SwiftUI

public class AudiobookPlaybackModel: ObservableObject {
  @Published private var reachability = Reachability()
  @Published var isWaitingForPlayer = false
  @Published var playbackProgress: Double = 0
  @Published var isDownloading = false
  @Published var overallDownloadProgress: Float = 0
  @Published var trackErrors: [String: Error] = [:]
  @Published var coverImage: UIImage?
  @Published var toastMessage: String = ""
  @Published private var _isPlaying: Bool = false

  private var subscriptions: Set<AnyCancellable> = []
  private(set) var audiobookManager: AudiobookManager

  @Published public var currentLocation: TrackPosition?
  private var pendingLocation: TrackPosition?
  private var suppressSavesUntil: Date?
  private var isNavigating = false

  var selectedLocation: TrackPosition? {
    didSet {
      guard let selectedLocation else {
        return
      }
      isNavigating = true

      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        if self.isNavigating {
          print("Navigation timeout reached - clearing navigation state")
          self.isNavigating = false
        }
      }

      if audiobookManager.audiobook.player.isLoaded && !isWaitingForPlayer {
        audiobookManager.audiobook.player.play(at: selectedLocation) { _ in
          DispatchQueue.main.async {
            self.isNavigating = false
          }
        }
      } else {
        pendingLocation = selectedLocation
        isNavigating = false
      }
      currentLocation = selectedLocation
      saveLocation()
      notifyHomeScreenOfPositionUpdate()
    }
  }

  let skipTimeInterval: TimeInterval = DefaultAudiobookManager.skipTimeInterval

  var offset: TimeInterval {
    if let currentLocation = currentLocation,
       let currentChapter = audiobookManager.currentChapter
    {
      do {
        let chapterOffset = try currentLocation - currentChapter.position
        return max(0.0, chapterOffset)
      } catch {
        return audiobookManager.currentOffset
      }
    }
    return audiobookManager.currentOffset
  }

  var duration: TimeInterval {
    audiobookManager.currentChapter?.duration ?? audiobookManager.currentDuration
  }

  var timeLeft: TimeInterval {
    max(duration - offset, 0.0)
  }

  var timeLeftInBook: TimeInterval {
    guard let currentLocation else {
      return audiobookManager.totalDuration
    }

    guard currentLocation.timestamp.isFinite else {
      return audiobookManager.totalDuration
    }

    return audiobookManager.totalDuration - currentLocation.durationToSelf()
  }

  var currentChapterTitle: String {
    if let currentLocation,
       let title = try? audiobookManager.audiobook.tableOfContents.chapter(forPosition: currentLocation).title
    {
      title
    } else if let title = audiobookManager.audiobook.tableOfContents.toc.first?.title, !title.isEmpty {
      title
    } else if let index = currentLocation?.track.index {
      String(format: "Track %d", index + 1)
    } else {
      "--"
    }
  }

  var playbackSliderValueDescription: String {
    let percent = playbackProgress * 100
    return String(format: Strings.ScrubberView.playbackSliderValueDescription, percent)
  }

  var isPlaying: Bool {
    _isPlaying
  }

  var tracks: [any Track] {
    audiobookManager.networkService.tracks
  }

  public init(audiobookManager: AudiobookManager) {
    self.audiobookManager = audiobookManager
    if let firstTrack = audiobookManager.audiobook.tableOfContents.allTracks.first {
      currentLocation = TrackPosition(
        track: firstTrack,
        timestamp: 0.0,
        tracks: audiobookManager.audiobook.tableOfContents.tracks
      )
    }

    _isPlaying = audiobookManager.audiobook.player.isPlaying

    setupBindings()
    subscribeToPublisher()
    setupReactivePlaybackStateMonitoring()
    self.audiobookManager.networkService.fetch()
  }

  // MARK: - Public helpers

  public func jumpToInitialLocation(_ position: TrackPosition) {
    pendingLocation = position
    currentLocation = position
  }

  public func beginSaveSuppression(for seconds: TimeInterval) {
    suppressSavesUntil = Date().addingTimeInterval(seconds)
  }

  private func subscribeToPublisher() {
    subscriptions.removeAll()

    audiobookManager.statePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else {
          return
        }
        switch state {
        case let .overallDownloadProgress(overallProgress):
          let isLCPStreaming = audiobookManager.audiobook.player is LCPStreamingPlayer
          isDownloading = !isLCPStreaming && overallProgress < 1
          // Clamp to max-seen-so-far to prevent the progress bar from sliding backwards
          overallDownloadProgress = max(overallDownloadProgress, overallProgress)
        case let .positionUpdated(position):
          guard let position else {
            return
          }

          currentLocation = position
          updateProgress()
          if let target = pendingLocation, audiobookManager.audiobook.player.isLoaded {
            pendingLocation = nil
            audiobookManager.audiobook.player.play(at: target) { _ in }
          }

        case let .playbackBegan(position):
          currentLocation = position
          isWaitingForPlayer = false
          _isPlaying = true
          isNavigating = false
          updateProgress()
          if let target = pendingLocation, audiobookManager.audiobook.player.isLoaded {
            pendingLocation = nil
            audiobookManager.audiobook.player.play(at: target) { _ in }
          }

        case let .playbackCompleted(position):
          currentLocation = position
          isWaitingForPlayer = false
          _isPlaying = false
          updateProgress()
          if let target = pendingLocation, audiobookManager.audiobook.player.isLoaded {
            pendingLocation = nil
            audiobookManager.audiobook.player.play(at: target) { _ in }
          }

        case .playbackUnloaded:
          _isPlaying = false
        case let .playbackFailed(position):
          isWaitingForPlayer = false
          _isPlaying = false
          if let position = position {
            ATLog(.error, "🚨 [AudiobookPlaybackModel] Playback error at position: \(position.timestamp)")
            ATLog(.error, "  Track: \(position.track.title ?? "unknown")")
            ATLog(.error, "  This may indicate corrupted file or decryption issues")
          } else {
            ATLog(.error, "🚨 [AudiobookPlaybackModel] Playback failed but position is nil - possibly SDK crash")
          }
          
          // Show error to user
          let errorMessage = "There was a problem playing this audiobook. It may be corrupted. Try re-downloading it."
          ATLog(.error, "  Showing error to user: \(errorMessage)")

        default:
          break
        }
      }
      .store(in: &subscriptions)
    audiobookManager.statePublisher
      .compactMap { state -> TrackPosition? in
        if case let .positionUpdated(pos) = state {
          return pos
        }
        return nil
      }
      .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
      .filter { [weak self] position in
        guard let self = self else {
          return false
        }
        if let currentLocation = currentLocation {
          return abs(currentLocation.timestamp - position.timestamp) > 2.0
        }
        return true
      }
      .sink { [weak self] _ in
        self?.saveLocation()
      }
      .store(in: &subscriptions)
    
    // MARK: - Fast UI Updates (0.25s via AVPlayer's periodic time observer)
    // This provides smooth slider and time display updates without expensive operations
    audiobookManager.audiobook.player.positionPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] position in
        guard let self = self else { return }
        currentLocation = position
        updateProgress()
      }
      .store(in: &subscriptions)

    audiobookManager.fetchBookmarks { _ in }
  }

  private func setupReactivePlaybackStateMonitoring() {
    Timer.publish(every: 0.5, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        guard let self = self else {
          return
        }
        let currentPlayingState = audiobookManager.audiobook.player.isPlaying
        if _isPlaying != currentPlayingState {
          _isPlaying = currentPlayingState
        }
      }
      .store(in: &subscriptions)
  }

  private func setupBindings() {
    reachability.startMonitoring()
    reachability.$isConnected
      .receive(on: RunLoop.current)
      .sink { [weak self] isConnected in
        if let self = self, isConnected && overallDownloadProgress != 0 {
          audiobookManager.networkService.fetch()
        }
      }
      .store(in: &subscriptions)
  }

  private func updateProgress() {
    guard duration > 0 else {
      playbackProgress = 0
      return
    }
    playbackProgress = offset / duration
  }

  deinit {
    self.reachability.stopMonitoring()
    self.audiobookManager.audiobook.player.unload()
    subscriptions.removeAll()
  }

  func playPause() {
    let wasPlaying = isPlaying
    if wasPlaying {
      audiobookManager.pause()
      _isPlaying = false
    } else {
      audiobookManager.play()
      _isPlaying = true
    }
    saveLocation()
  }

  func pause() {
    saveLocation()
    audiobookManager.pause()
  }

  private func notifyHomeScreenOfPositionUpdate() {
    guard let currentLocation = currentLocation else {
      return
    }

    DispatchQueue.main.async { [weak self] in
      self?.audiobookManager.updateNowPlayingInfo(currentLocation)
    }
  }

  func stop() {
    _isPlaying = false
    saveLocation()
    audiobookManager.unload()
    subscriptions.removeAll()
  }

  private func saveLocation() {
    if let until = suppressSavesUntil, Date() < until {
      return
    }
    if let currentLocation {
      audiobookManager.saveLocation(currentLocation)
    }
  }

  /// Force-saves the current position, bypassing any active save suppression.
  /// Use for critical lifecycle events (termination, backgrounding) where data
  /// loss is unacceptable.
  public func persistLocation() {
    suppressSavesUntil = nil
    if let currentLocation {
      audiobookManager.saveLocation(currentLocation)
    }
  }

  func skipBack() {
    guard !isWaitingForPlayer || audiobookManager.audiobook.player.queuesEvents else {
      return
    }

    isWaitingForPlayer = true

    audiobookManager.audiobook.player.skipPlayhead(-skipTimeInterval) { [weak self] adjustedLocation in
      DispatchQueue.main.async {
        guard let self = self else {
          return
        }

        if let adjustedLocation = adjustedLocation {
          self.currentLocation = adjustedLocation
          self.saveLocation()
          self.notifyHomeScreenOfPositionUpdate()
        } else {
          if let currentLocation = self.currentLocation {
            let fallbackPosition = currentLocation + (-self.skipTimeInterval)
            self.currentLocation = fallbackPosition
            self.saveLocation()
            self.notifyHomeScreenOfPositionUpdate()
            ATLog(.debug, "Skip back used fallback position calculation")
          }
        }

        // Force UI progress update immediately after skip
        self.updateProgress()
        self.isWaitingForPlayer = false
      }
    }
  }

  func skipForward() {
    guard !isWaitingForPlayer || audiobookManager.audiobook.player.queuesEvents else {
      return
    }

    isWaitingForPlayer = true

    audiobookManager.audiobook.player.skipPlayhead(skipTimeInterval) { [weak self] adjustedLocation in
      DispatchQueue.main.async {
        guard let self = self else {
          return
        }

        if let adjustedLocation = adjustedLocation {
          self.currentLocation = adjustedLocation
          self.saveLocation()
          self.notifyHomeScreenOfPositionUpdate()
        } else {
          if let currentLocation = self.currentLocation {
            let fallbackPosition = currentLocation + self.skipTimeInterval
            self.currentLocation = fallbackPosition
            self.saveLocation()
            self.notifyHomeScreenOfPositionUpdate()
            ATLog(.debug, "Skip forward used fallback position calculation")
          }
        }

        // Force UI progress update immediately after skip
        self.updateProgress()
        self.isWaitingForPlayer = false
      }
    }
  }

  func move(to value: Double) {
    guard !isNavigating else {
      print("Seek blocked: navigation in progress")
      return
    }

    if let modernManager = audiobookManager as? DefaultAudiobookManager {
      modernManager.seekWithSlider(value: value) { [weak self] adjustedLocation in
        self?.currentLocation = adjustedLocation
        self?.saveLocation()
      }
    } else {
      // Legacy fallback
      audiobookManager.audiobook.player.move(to: value) { [weak self] adjustedLocation in
        self?.currentLocation = adjustedLocation
        self?.saveLocation()
      }
    }
  }

  public func downloadProgress(for chapter: Chapter) -> Double {
    audiobookManager.downloadProgress(for: chapter)
  }

  func setPlaybackRate(_ playbackRate: PlaybackRate) {
    audiobookManager.audiobook.player.playbackRate = playbackRate
  }

  func setSleepTimer(_ trigger: SleepTimerTriggerAt) {
    audiobookManager.sleepTimer.setTimerTo(trigger: trigger)
  }

  func addBookmark(completion: @escaping (_ error: Error?) -> Void) {
    guard let currentLocation else {
      completion(BookmarkError.bookmarkFailedToSave)
      return
    }

    audiobookManager.saveBookmark(at: currentLocation) { result in
      switch result {
      case .success:
        completion(nil)
      case let .failure(error):
        completion(error)
      }
    }
  }

  // MARK: - Player timer delegate

  func audiobookManager(_ audiobookManager: AudiobookManager, didUpdate _: Timer?) {
    currentLocation = audiobookManager.audiobook.player.currentTrackPosition
  }

  // MARK: - PlayerDelegate

  func player(_: Player, didBeginPlaybackOf track: any Track) {
    currentLocation = TrackPosition(
      track: track,
      timestamp: 0,
      tracks: audiobookManager.audiobook.player.tableOfContents.tracks
    )
    isWaitingForPlayer = false
  }

  func player(_: Player, didStopPlaybackOf trackPosition: TrackPosition) {
    currentLocation = trackPosition
    isWaitingForPlayer = false
  }

  func player(_: Player, didComplete _: any Track) {
    isWaitingForPlayer = false
  }

  func player(_: Player, didFailPlaybackOf _: any Track, withError _: NSError?) {
    isWaitingForPlayer = false
  }

  func playerDidUnload(_: Player) {
    isWaitingForPlayer = false
  }

  // MARK: - Media Player

  public func updateCoverImage(_ image: UIImage?) {
    coverImage = image
    updateLockScreenCoverArtwork(image: image)
  }

  private func updateLockScreenCoverArtwork(image: UIImage?) {
    DispatchQueue.main.async {
      if let image = image {
        let itemArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
          image
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        info[MPMediaItemPropertyArtwork] = itemArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
  }
}
