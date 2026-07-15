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
  @Published public var isDownloading = false
  @Published public var overallDownloadProgress: Float = 0
  @Published var trackErrors: [String: Error] = [:]
  @Published var coverImage: UIImage?
  @Published public var toastMessage: String = ""
  @Published private var _isPlaying: Bool = false

  private var subscriptions: Set<AnyCancellable> = []
  private(set) var audiobookManager: AudiobookManager

  @Published public var currentLocation: TrackPosition?
  private var pendingLocation: TrackPosition?
  private var suppressSavesUntil: Date?
  private var suppressPlaybackPollUntil: Date?
  // While a skip/seek is settling, the SDK buffers→resumes and briefly emits
  // transient position/`.playbackBegan` events (chapter start, chapter end,
  // momentarily-not-playing). Holding the display at the user's skip target
  // through this window prevents the progress bar / title / play-button from
  // flickering to those bogus intermediate values.
  private var suppressPositionUpdatesUntil: Date?
  private var isNavigating = false

  private var isSuppressingPositionUpdates: Bool {
    if let until = suppressPositionUpdatesUntil { return Date() < until }
    return false
  }

  /// Begins (or extends) the post-skip suppression window. Rapid skips keep
  /// pushing it out so the display tracks the latest target, not the churn.
  private func suppressTransientPlaybackUpdates(for seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    suppressPositionUpdatesUntil = until
    suppressPlaybackPollUntil = until
  }

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
        let target = selectedLocation
        Task { [weak self] in
          _ = try? await self?.audiobookManager.audiobook.player.play(at: target)
          await MainActor.run { self?.isNavigating = false }
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

  /// Independently-configurable skip intervals, read live from the manager so a
  /// host's Playback-settings change applies to subsequently opened audiobooks.
  var skipForwardInterval: TimeInterval { audiobookManager.skipForwardInterval }
  var skipBackInterval: TimeInterval { audiobookManager.skipBackInterval }

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
          isDownloading = AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: overallProgress)
          // Clamp to max-seen-so-far to prevent the progress bar from sliding backwards
          overallDownloadProgress = max(overallDownloadProgress, overallProgress)
        case let .positionUpdated(position):
          guard let position else {
            return
          }
          if isSuppressingPositionUpdates { break }

          currentLocation = position
          updateProgress()
          if let target = pendingLocation, audiobookManager.audiobook.player.isLoaded {
            pendingLocation = nil
            Task { [weak self] in
              _ = try? await self?.audiobookManager.audiobook.player.play(at: target)
            }
          }

        case let .playbackBegan(position):
          // `.playbackBegan` fires on every buffer→resume during a skip burst,
          // often carrying the chapter-start position; keep the play-state flags
          // but don't let it yank the displayed location off the skip target.
          if !isSuppressingPositionUpdates {
            currentLocation = position
            updateProgress()
          }
          isWaitingForPlayer = false
          _isPlaying = true
          isNavigating = false
          if let target = pendingLocation, audiobookManager.audiobook.player.isLoaded {
            pendingLocation = nil
            Task { [weak self] in
              _ = try? await self?.audiobookManager.audiobook.player.play(at: target)
            }
          }

        case let .playbackCompleted(position):
          isWaitingForPlayer = false
          // During a skip burst the SDK can emit a chapter-`.completed` at the
          // chapter END as it tears down to reload — which would slam the
          // progress bar to the end and the button to paused. Ignore it while
          // the skip is settling; a real end-of-chapter resolves after the
          // window via the subsequent `.playbackBegan` for the next chapter.
          if !isSuppressingPositionUpdates {
            currentLocation = position
            _isPlaying = false
            updateProgress()
          }
          if let target = pendingLocation, audiobookManager.audiobook.player.isLoaded {
            pendingLocation = nil
            Task { [weak self] in
              _ = try? await self?.audiobookManager.audiobook.player.play(at: target)
            }
          }

        case .playbackUnloaded:
          _isPlaying = false
          isNavigating = false
        case let .playbackFailed(position, error):
          isWaitingForPlayer = false
          _isPlaying = false
          isNavigating = false

          let nsError = error as NSError?
          let openAccessError: OpenAccessPlayerError? = {
            guard let nsError = nsError else { return nil }
            if nsError.domain == OpenAccessPlayerErrorDomain {
              return OpenAccessPlayerError(rawValue: nsError.code)
            }
            // AVFoundation wraps HTTP 403 as NSURLErrorNoPermissionsToReadFile
            // (-1102) before the error reaches us — by the time playback hits
            // the AVPlayerItem, the OpenAccessPlayerError.contentForbidden we
            // published from OpenAccessDownloadTask has been re-typed by the
            // system networking layer. Treat -1102 as contentForbidden so the
            // patron sees "Title Unavailable" instead of generic.
            if nsError.domain == NSURLErrorDomain {
              switch nsError.code {
              case NSURLErrorNoPermissionsToReadFile:
                return .contentForbidden
              case NSURLErrorUserAuthenticationRequired:
                return .authenticationRequired
              case NSURLErrorNotConnectedToInternet,
                   NSURLErrorNetworkConnectionLost,
                   NSURLErrorTimedOut:
                return .connectionLost
              default:
                return nil
              }
            }
            return nil
          }()

          if let position = position {
            ATLog(.error, "🚨 [AudiobookPlaybackModel] Playback error at position: \(position.timestamp)")
            ATLog(.error, "  Track: \(position.track.title ?? "unknown")")
            if let nsError = nsError {
              let status = nsError.userInfo["httpStatusCode"] as? Int
              let url = nsError.userInfo["url"] as? String
              ATLog(.error, "  Underlying error: \(nsError.domain) code=\(nsError.code) http=\(status.map { "\($0)" } ?? "n/a") url=\(url ?? "n/a")")
            } else {
              ATLog(.error, "  No underlying error provided — may indicate corrupted file or decryption issues")
            }
          } else {
            ATLog(.error, "🚨 [AudiobookPlaybackModel] Playback failed but position is nil - possibly SDK crash")
          }

          // Surface a specific message when we have one, fall back to generic
          // only when the error is unknown / nil. Previously every failure
          // showed "A Problem Has Occurred" — including 403 Forbidden, which
          // patrons could not act on. Now contentForbidden / connectionLost /
          // drmExpired / authenticationRequired each get their own copy.
          let errorMessage: String
          if let oaError = openAccessError, oaError != .unknown {
            errorMessage = "\(oaError.errorTitle()). \(oaError.errorDescription())"
          } else {
            errorMessage = "\(Strings.AudiobookPlayerViewController.problemHasOccurred). \(Strings.AudiobookPlayerViewController.tryAgain)"
          }
          ATLog(.error, "  Showing error to user: \(errorMessage)")
          toastMessage = errorMessage

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
        // Hold the user's skip target while the seek settles; ignore the
        // transient positions the SDK emits during the buffer→resume.
        if isSuppressingPositionUpdates { return }
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
        guard let self = self else { return }
        if let suppress = suppressPlaybackPollUntil, Date() < suppress { return }
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
    suppressPlaybackPollUntil = Date().addingTimeInterval(1.0)
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
    persistLocation()
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
    // Hold the UI at the skip target through the SDK's buffer→resume so rapid
    // skips don't flicker the progress bar / title / play-button.
    suppressTransientPlaybackUpdates(for: 1.5)

    Task { [weak self] in
      guard let self = self else { return }
      let adjustedLocation = await self.audiobookManager.audiobook.player.skipPlayhead(-self.skipBackInterval)
      await MainActor.run {
        if let adjustedLocation = adjustedLocation {
          self.currentLocation = adjustedLocation
          self.saveLocation()
          self.notifyHomeScreenOfPositionUpdate()
        } else {
          if let currentLocation = self.currentLocation {
            let fallbackPosition = currentLocation + (-self.skipBackInterval)
            self.currentLocation = fallbackPosition
            self.saveLocation()
            self.notifyHomeScreenOfPositionUpdate()
            ATLog(.debug, "Skip back used fallback position calculation")
          }
        }
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
    // Hold the UI at the skip target through the SDK's buffer→resume so rapid
    // skips don't flicker the progress bar / title / play-button.
    suppressTransientPlaybackUpdates(for: 1.5)

    Task { [weak self] in
      guard let self = self else { return }
      let adjustedLocation = await self.audiobookManager.audiobook.player.skipPlayhead(self.skipForwardInterval)
      await MainActor.run {
        if let adjustedLocation = adjustedLocation {
          self.currentLocation = adjustedLocation
          self.saveLocation()
          self.notifyHomeScreenOfPositionUpdate()
        } else {
          if let currentLocation = self.currentLocation {
            let fallbackPosition = currentLocation + self.skipForwardInterval
            self.currentLocation = fallbackPosition
            self.saveLocation()
            self.notifyHomeScreenOfPositionUpdate()
            ATLog(.debug, "Skip forward used fallback position calculation")
          }
        }
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
      Task { [weak self] in
        let adjustedLocation = await self?.audiobookManager.audiobook.player.move(to: value)
        await MainActor.run {
          self?.currentLocation = adjustedLocation
          self?.saveLocation()
        }
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

  public func addBookmark(completion: @escaping (_ error: Error?) -> Void) {
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

  /// Updates the cover with a cross-fade — use this when upgrading from a
  /// low-res placeholder to the full-resolution player image.
  public func updateCoverImageAnimated(_ image: UIImage?) {
    withAnimation(.easeInOut(duration: 0.3)) {
      coverImage = image
    }
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

// MARK: - Chapter-relative time accessors (in-app custom player)
public extension AudiobookPlaybackModel {
  /// Chapter-relative playhead position, in seconds from the start of the
  /// current chapter. This is the raw `TimeInterval` behind the toolkit
  /// player's `playheadOffsetText` timecode — exposed (not the formatted
  /// string) so an in-app custom player can format it itself.
  var chapterPlayheadOffset: TimeInterval { offset }

  /// Seconds remaining in the current chapter — the raw `TimeInterval`
  /// behind the toolkit player's `timeLeftText` timecode.
  var chapterTimeLeft: TimeInterval { timeLeft }
}

// MARK: - PP-4156 download-indicator visibility rule
public extension AudiobookPlaybackModel {
  /// Whether the player's download-progress indicator should be visible for a given
  /// overall download progress value. The rule is intentionally a function of progress
  /// only — adding a player-type parameter (as a prior commit did) hid the indicator
  /// for LCP audiobooks even while their tracks were still decrypting in the background.
  /// PP-4156: PR introduced via git, see retrospective for full context.
  static func shouldShowDownloadIndicator(forOverallProgress progress: Float) -> Bool {
    progress < 1
  }
}
