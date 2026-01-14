//
//  OpenAccessPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/1/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation

let AudioInterruptionNotification = AVAudioSession.interruptionNotification
let AudioRouteChangeNotification = AVAudioSession.routeChangeNotification

// MARK: - OpenAccessPlayer

class OpenAccessPlayer: NSObject, Player {
  let avQueuePlayer: AVQueuePlayer
  var playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
  var tableOfContents: AudiobookTableOfContents
  var isPlaying: Bool {
    avQueuePlayer.rate != .zero
  }

  // MARK: - Fast UI Position Updates (0.25s interval)
  private let positionSubject = PassthroughSubject<TrackPosition, Never>()
  private var timeObserverToken: Any?
  
  var positionPublisher: AnyPublisher<TrackPosition, Never> {
    positionSubject.eraseToAnyPublisher()
  }

  private var debounceWorkItem: DispatchWorkItem?

  var taskCompleteNotification: Notification.Name {
    OpenAccessTaskCompleteNotification
  }

  var queuesEvents: Bool = false
  var taskCompletion: Completion?
  var isLoaded: Bool = false
  var queuedTrackPosition: TrackPosition?

  var currentOffset: Double {
    guard let currentTrackPosition, let currentChapter else {
      return 0.0
    }

    let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
    return max(0.0, offset) // Ensure non-negative
  }

  var isDrmOk: Bool = true {
    didSet {
      if !isDrmOk {
        pause()
        playbackStatePublisher.send(
          .failed(
            currentTrackPosition,
            NSError(
              domain: errorDomain,
              code: OpenAccessPlayerError.drmExpired.rawValue,
              userInfo: nil
            )
          )
        )
        unload()
      }
    }
  }

  var playbackRate: PlaybackRate {
    set {
      avQueuePlayer.rate = PlaybackRate.convert(rate: newValue)
      savePlaybackRate(rate: newValue)
    }

    get {
      fetchPlaybackRate() ?? .normalTime
    }
  }

  var currentChapter: Chapter? {
    guard let currentTrackPosition else {
      return nil
    }

    return try? tableOfContents.chapter(forPosition: currentTrackPosition)
  }

  var currentTrackPosition: TrackPosition? {
    // Return queued position if seeking is in progress
    if let queuedPosition = queuedTrackPosition {
      return queuedPosition
    }
    
    guard let currentItem = avQueuePlayer.currentItem,
          let currentTrack = tableOfContents.track(forKey: currentItem.trackIdentifier ?? "")
    else {
      // Validate position refers to a valid track before returning
      if let lastPos = lastKnownPosition {
        if tableOfContents.track(forKey: lastPos.track.key) != nil {
          return lastPos
        } else {
          ATLog(.warn, "OpenAccessPlayer: lastKnownPosition refers to invalid track, resetting")
          resetToBeginning()
          return lastKnownPosition
        }
      }
      return lastKnownPosition
    }

    // PERFORMANCE OPTIMIZATION: Cache position to reduce expensive AVPlayer.currentTime() calls
    let currentTime = currentItem.currentTime().seconds

    guard currentTime.isFinite else {
      ATLog(.debug, "OpenAccessPlayer: currentTime is not finite, validating lastKnownPosition")
      return validateAndReturnLastKnownPosition()
    }

    if let lastPosition = lastKnownPosition,
       lastPosition.track.key == currentTrack.key,
       abs(lastPosition.timestamp - currentTime) < 0.5
    { // Increased threshold to reduce updates
      return lastPosition
    }

    let position = TrackPosition(
      track: currentTrack,
      timestamp: currentTime,
      tracks: tableOfContents.tracks
    )
    lastKnownPosition = position
    return position
  }
  
  /// Validates lastKnownPosition and returns it only if valid.
  /// If invalid, resets to beginning and returns that position.
  private func validateAndReturnLastKnownPosition() -> TrackPosition? {
    guard let lastPos = lastKnownPosition else {
      return nil
    }
    
    // Check if the track still exists in our table of contents
    guard tableOfContents.track(forKey: lastPos.track.key) != nil else {
      ATLog(.warn, "OpenAccessPlayer: lastKnownPosition track '\(lastPos.track.key)' not found in TOC, resetting")
      resetToBeginning()
      return lastKnownPosition
    }
    
    // Check if timestamp is valid (not negative, not beyond track duration)
    let trackDuration = lastPos.track.duration
    if lastPos.timestamp < 0 || (trackDuration > 0 && lastPos.timestamp > trackDuration) {
      ATLog(.warn, "OpenAccessPlayer: lastKnownPosition timestamp \(lastPos.timestamp) invalid for track duration \(trackDuration), resetting")
      resetToBeginning()
      return lastKnownPosition
    }
    
    return lastPos
  }
  
  /// Resets position to the beginning of the first track.
  /// Called when position state becomes invalid/stale.
  private func resetToBeginning() {
    guard let firstTrack = tableOfContents.allTracks.first else {
      ATLog(.error, "OpenAccessPlayer: Cannot reset to beginning, no tracks available")
      lastKnownPosition = nil
      return
    }
    
    let beginningPosition = TrackPosition(
      track: firstTrack,
      timestamp: 0.0,
      tracks: tableOfContents.tracks
    )
    lastKnownPosition = beginningPosition
    ATLog(.info, "OpenAccessPlayer: Reset position to beginning of track: \(firstTrack.title ?? firstTrack.key)")
  }

  private var cancellables = Set<AnyCancellable>()
  public var lastKnownPosition: TrackPosition?
  private var isObservingPlayerStatus = false
  private var bearerToken: String?

  private var playerIsReady: AVPlayerItem.Status = .readyToPlay {
    didSet {
      handlePlayerStatusChange()
    }
  }

  private var errorDomain: String {
    OpenAccessPlayerErrorDomain
  }

  required init(tableOfContents: AudiobookTableOfContents) {
    self.tableOfContents = tableOfContents
    avQueuePlayer = AVQueuePlayer()
    bearerToken = tableOfContents.tracks.token
    super.init()
    
    if let firstTrack = tableOfContents.allTracks.first {
      lastKnownPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
    }
    configurePlayer()
    addPlayerObservers()
  }

  func configurePlayer() {
    setupAudioSession()
    buildPlayerQueue()
  }

  private func handlePlaybackError(_ error: OpenAccessPlayerError) {
    ATLog(.error, "OpenAccessPlayer: Playback error occurred: \(error), clearing position state")
    
    // Preserve position for error reporting, then clear stale state
    let errorPosition = currentTrackPosition
    clearQueuedPosition()
    
    playbackStatePublisher.send(.failed(errorPosition, NSError(domain: errorDomain, code: error.rawValue)))
    unload()
  }
  
  /// Clears any queued position and optionally resets lastKnownPosition.
  private func clearQueuedPosition() {
    queuedTrackPosition = nil
    ATLog(.debug, "OpenAccessPlayer: Cleared queued position")
  }

  private func attemptToPlay(_ trackPosition: TrackPosition) {
    switch playerIsReady {
    case .readyToPlay:
      avQueuePlayer.play()
      restorePlaybackRate()
      isLoaded = true
      playbackStatePublisher.send(.started(trackPosition))
    default:
      handlePlaybackError(.playerNotReady)
    }
  }

  func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
    ATLog(.warn, "🎯 [OpenAccessPlayer] play(at:) CALLED - track=\(position.track.key), timestamp=\(position.timestamp)")
    queuedTrackPosition = position
    
    seekTo(position: position) { [weak self] trackPosition in
      guard let self = self else { return }
      
      if trackPosition == nil {
        ATLog(.error, "OpenAccessPlayer: Seek failed for \(position.track.title ?? "track"), not starting playback")
        let error = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.unknown.rawValue,
          userInfo: [NSLocalizedDescriptionKey: "Failed to load audio track"]
        )
        playbackStatePublisher.send(.failed(position, error))
        completion?(error)
        return
      }
      
      queuedTrackPosition = nil
      avQueuePlayer.play()
      restorePlaybackRate()
      isLoaded = true
      if let startedPos = trackPosition {
        playbackStatePublisher.send(.started(startedPos))
      } else {
        playbackStatePublisher.send(.started(position))
      }
      completion?(nil)
    }
  }

  func play() {
    debouncePlayPauseAction {
      if !self.isLoaded || self.currentTrackPosition == nil {
        if self.avQueuePlayer.items().isEmpty {
          self.buildPlayerQueue()
        }
        if let position = self.currentTrackPosition ?? self.tableOfContents.allTracks.first.map({ TrackPosition(
          track: $0,
          timestamp: 0.0,
          tracks: self.tableOfContents.tracks
        ) }) {
          self.attemptToPlay(position)
          self.avQueuePlayer.rate = PlaybackRate.convert(rate: self.playbackRate)
        }
        return
      }

      guard let currentTrackPosition = self.currentTrackPosition else {
        return
      }

      if !self.isDrmOk {
        self.handlePlaybackError(.drmExpired)
        return
      }

      self.attemptToPlay(currentTrackPosition)
      self.avQueuePlayer.rate = PlaybackRate.convert(rate: self.playbackRate)
    }
  }

  func pause() {
    debouncePlayPauseAction {
      self.clearPositionCache()
      self.avQueuePlayer.pause()
      if let trackPosition = self.currentTrackPosition {
        self.playbackStatePublisher.send(.stopped(trackPosition))
      }
    }
  }

  private func debouncePlayPauseAction(action: @escaping () -> Void) {
    debounceWorkItem?.cancel()
    debounceWorkItem = DispatchWorkItem { [weak self] in
      self?.synchronizedAccess(action)
    }
    // PERFORMANCE OPTIMIZATION: Use background queue for debounced actions to reduce main thread pressure
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: debounceWorkItem!)
  }

  private func synchronizedAccess(_ action: () -> Void) {
    objc_sync_enter(self)
    defer { objc_sync_exit(self) }
    action()
  }

  func unload() {
    avQueuePlayer.removeAllItems()
    isLoaded = false
    playbackStatePublisher.send(.unloaded)
    removePlayerObservers()
    cancellables.removeAll()
  }

  func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
    guard let task else {
      return nil
    }
    return task.assetFileStatus()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    try? AVAudioSession.sharedInstance().setActive(false, options: [])
    unload()
    removePlayerObservers()
    clearPositionCache()
  }

  func clearPositionCache() {
    lastKnownPosition = nil
  }

  private func handlePlayerStatusChange() {
    switch playerIsReady {
    case .readyToPlay:
      guard !isPlaying else {
        return
      }
      play()

    case .unknown:
      handleUnknownPlayerStatus()

    case .failed:
      ATLog(.error, "Player failed to load the media")

    default:
      break
    }
  }

  private func handleUnknownPlayerStatus() {
    guard avQueuePlayer.currentItem == nil else {
      return
    }

    if let fileStatus = assetFileStatus(currentTrackPosition?.track.downloadTask) {
      switch fileStatus {
      case let .saved(savedURLs):
        guard let item = createPlayerItem(files: savedURLs) else {
          return
        }

        if avQueuePlayer.canInsert(item, after: nil) {
          avQueuePlayer.insert(item, after: nil)
        }

      case .missing:
        // If local files are missing (offloaded), temporarily stream the remote URL
        if let track = currentTrackPosition?.track, let streamingItem = createPlayerItem(from: track) {
          if avQueuePlayer.canInsert(streamingItem, after: nil) {
            avQueuePlayer.insert(streamingItem, after: nil)
          }
        }
        // And also kick off a re-download in the background
        listenForDownloadCompletion()

      default:
        break
      }
    }
  }

  public func listenForDownloadCompletion(task: DownloadTask? = nil) {
    (task ?? currentTrackPosition?.track.downloadTask)?.statePublisher
      .receive(on: DispatchQueue.main)
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          self.updatePlayerQueueIfNeeded()
        case let .failure(error):
          ATLog(.error, "Download failed with error: \(error)")
        }
      }, receiveValue: { [weak self] state in
        if case .completed = state {
          self?.updatePlayerQueueIfNeeded()
        }
      })
      .store(in: &cancellables)
  }

  private func updatePlayerQueueIfNeeded() {
    let trackToCheck = currentTrackPosition?.track ?? tableOfContents.allTracks.first

    guard let track = trackToCheck,
          let fileStatus = assetFileStatus(track.downloadTask),
          case let .saved(urls) = fileStatus
    else {
      return
    }

    if !isLoaded {
      if let currentAssetURL = (avQueuePlayer.currentItem?.asset as? AVURLAsset)?.url,
         urls.contains(currentAssetURL)
      {
        rebuildPlayerQueueAndNavigate(to: currentTrackPosition)
      } else if currentTrackPosition == nil || tableOfContents.allTracks.first?.id == track.id {
        buildPlayerQueue()
        if tableOfContents.allTracks.first != nil {
          avQueuePlayer.pause()
          ATLog(.debug, "OpenAccessPlayer: Queue built, ready for playback at first track")
          isLoaded = true
        }
      } else {
        rebuildPlayerQueueAndNavigate(to: currentTrackPosition)
      }
    }
  }

  public func buildPlayerQueue() {
    resetPlayerQueue()

    let allTracks = tableOfContents.allTracks
    let isOverdrive = tableOfContents.manifest.audiobookType == .overdrive

    let tracksToLoad: [any Track]
    if isOverdrive {
      tracksToLoad = allTracks
      ATLog(.debug, "OpenAccessPlayer: Building full queue for Overdrive - \(allTracks.count) tracks")
    } else {
      let windowSize = 5 // Load only 5 tracks at a time for faster initialization

      var currentIndex = 0
      if let position = lastKnownPosition {
        currentIndex = allTracks.firstIndex { $0.key == position.track.key } ?? position.track.index
      }

      let startIndex = max(0, currentIndex - 1)
      let endIndex = min(allTracks.count - 1, currentIndex + windowSize - 1)
      tracksToLoad = Array(allTracks[startIndex...endIndex])

      ATLog(
        .debug,
        "OpenAccessPlayer: Building queue window - tracks \(startIndex) to \(endIndex) of \(allTracks.count)"
      )
    }

    let playerItems = buildPlayerItems(fromTracks: tracksToLoad)
    if playerItems.isEmpty {
      if let firstTrack = allTracks.first {
        let firstItems = buildPlayerItems(fromTracks: [firstTrack])
        if firstItems.isEmpty {
          isLoaded = false
          return
        }
        for item in firstItems {
          if avQueuePlayer.canInsert(item, after: nil) {
            avQueuePlayer.insert(item, after: nil)
            addEndObserver(for: item)
          }
        }
      } else {
        isLoaded = false
        return
      }
    } else {
      for item in playerItems {
        if avQueuePlayer.canInsert(item, after: nil) {
          avQueuePlayer.insert(item, after: nil)
          addEndObserver(for: item)
        } else {
          isLoaded = avQueuePlayer.items().count > 0
          return
        }
      }
    }

    avQueuePlayer.automaticallyWaitsToMinimizeStalling = true

    avQueuePlayer.pause()
    if !avQueuePlayer.items().isEmpty,
       let firstTrack = tableOfContents.allTracks.first
    {
      lastKnownPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
      ATLog(.debug, "OpenAccessPlayer: Set initial position to first track: \(firstTrack.title ?? firstTrack.key)")
    }

    isLoaded = true
  }

  public func rebuildPlayerQueueAndNavigate(
    to trackPosition: TrackPosition?,
    shouldResumePlayback: Bool = true,
    completion: ((Bool) -> Void)? = nil
  ) {
    let wasPlaying = avQueuePlayer.rate > 0
    avQueuePlayer.pause()
    
    if let trackPosition = trackPosition {
      lastKnownPosition = trackPosition
    }

    resetPlayerQueue()
    let playerItems = buildPlayerItems(fromTracks: tableOfContents.allTracks)

    guard !playerItems.isEmpty else {
      ATLog(.error, "OpenAccessPlayer: Failed to build player items for queue rebuild")
      completion?(false)
      return
    }

    var desiredIndex: Int?
    for (index, item) in playerItems.enumerated() {
      avQueuePlayer.insert(item, after: nil)
      addEndObserver(for: item)
      // Use item's trackIdentifier to match target position (not array index, which can be misaligned if tracks were skipped)
      if let trackPos = trackPosition, item.trackIdentifier == trackPos.track.key {
        desiredIndex = index
      }
    }

    // Default to first chapter if no explicit target position was provided
    let targetIndex = desiredIndex ?? 0
    
<<<<<<< HEAD
=======
    if desiredIndex == nil, let trackPos = trackPosition {
      ATLog(.warn, "⚠️ [rebuildPlayerQueueAndNavigate] Track not found in player items! target track key=\(trackPos.track.key)")
      ATLog(.warn, "⚠️ [rebuildPlayerQueueAndNavigate] Available item keys: \(playerItems.compactMap { $0.trackIdentifier }.joined(separator: ", "))")
      ATLog(.warn, "⚠️ [rebuildPlayerQueueAndNavigate] Defaulting to index 0 (first track)")
    }
    
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
    guard targetIndex < playerItems.count else {
      ATLog(.error, "OpenAccessPlayer: Target index \(targetIndex) out of bounds (\(playerItems.count) items)")
      completion?(false)
      return
    }

    let targetTimestamp = trackPosition?.timestamp ?? 0.0
    ATLog(.warn, "🎯 [rebuildPlayerQueueAndNavigate] Navigating to index=\(targetIndex), timestamp=\(targetTimestamp), track=\(playerItems[targetIndex].trackIdentifier ?? "unknown")")
    navigateToItem(at: targetIndex, with: targetTimestamp) { [weak self] success in
      if success && wasPlaying && shouldResumePlayback {
        // Restore playback state after successful navigation
        self?.avQueuePlayer.play()
        self?.restorePlaybackRate()
      }
      completion?(success)
    }
  }

  public func resetPlayerQueue() {
    for item in avQueuePlayer.items() {
      removeEndObserver(for: item)
    }
    avQueuePlayer.removeAllItems()
  }

  public func addEndObserver(for item: AVPlayerItem) {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemDidReachEnd(_:)),
      name: .AVPlayerItemDidPlayToEndTime,
      object: item
    )
  }

  public func removeEndObserver(for item: AVPlayerItem) {
    NotificationCenter.default.removeObserver(
      self,
      name: .AVPlayerItemDidPlayToEndTime,
      object: item
    )
  }

  public func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
    guard let currentTrackPosition = currentTrackPosition ?? lastKnownPosition else {
      completion?(nil)
      return
    }

    let newPosition = currentTrackPosition + timeInterval
    seekTo(position: newPosition, completion: completion)
  }

  public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
    ATLog(.warn, "🔍 [OpenAccessPlayer] seekTo() CALLED - track=\(position.track.key), timestamp=\(position.timestamp)")
    if avQueuePlayer.currentItem?.trackIdentifier == position.track.key {
      performSeek(to: position, completion: completion)
    } else if let _ = avQueuePlayer.items().first(where: { $0.trackIdentifier == position.track.key }) {
      navigateToPosition(position, in: avQueuePlayer.items(), completion: completion)
    } else {
      if canInsertTrackIntoQueue(position.track) {
        insertTrackAndNavigate(to: position, completion: completion)
      } else {
        // Fall back to full rebuild only when necessary
        rebuildPlayerQueueAndNavigate(to: position, shouldResumePlayback: false) { [weak self] success in
          if success {
            self?.performSeek(to: position, completion: completion)
          } else {
            completion?(nil)
          }
        }
      }
    }
  }

  private func canInsertTrackIntoQueue(_ track: any Track) -> Bool {
    let allTracks = tableOfContents.allTracks
    let currentItems = avQueuePlayer.items()

    guard currentItems.count > 5,
          let targetIndex = allTracks.firstIndex(where: { $0.key == track.key })
    else {
      return false
    }

    let existingIndices = currentItems.compactMap { item in
      allTracks.firstIndex { $0.key == item.trackIdentifier }
    }.sorted()

    if let firstExisting = existingIndices.first,
       let lastExisting = existingIndices.last
    {
      return targetIndex >= max(0, firstExisting - 3) &&
        targetIndex <= min(allTracks.count - 1, lastExisting + 3)
    }

    return false
  }

  private func insertTrackAndNavigate(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
    let allTracks = tableOfContents.allTracks
    guard let targetIndex = allTracks.firstIndex(where: { $0.key == position.track.key }) else {
      completion?(nil)
      return
    }

    let track = allTracks[targetIndex]
    guard let newItem = createPlayerItem(from: track) else {
      completion?(nil)
      return
    }

    let currentItems = avQueuePlayer.items()
    var insertAfter: AVPlayerItem?

    for item in currentItems {
      if let trackIndex = allTracks.firstIndex(where: { $0.key == item.trackIdentifier }),
         trackIndex < targetIndex
      {
        insertAfter = item
      } else {
        break
      }
    }

    if avQueuePlayer.canInsert(newItem, after: insertAfter) {
      avQueuePlayer.insert(newItem, after: insertAfter)
      addEndObserver(for: newItem)

      navigateToPosition(position, in: avQueuePlayer.items(), completion: completion)
    } else {
      rebuildPlayerQueueAndNavigate(to: position, shouldResumePlayback: false) { [weak self] success in
        if success {
          self?.performSeek(to: position, completion: completion)
        } else {
          completion?(nil)
        }
      }
    }
  }

  public func navigateToItem(at index: Int, with timestamp: TimeInterval, completion: ((Bool) -> Void)? = nil) {
    let shouldPlay = avQueuePlayer.rate > 0

    avQueuePlayer.pause()

    for _ in 0..<index {
      avQueuePlayer.advanceToNextItem()
    }

    guard let currentItem = avQueuePlayer.currentItem else {
      completion?(false)
      return
    }

    // Wait for item to be ready before seeking
    if currentItem.status == .readyToPlay {
      performSeekOnItem(currentItem, to: timestamp, shouldPlay: shouldPlay, completion: completion)
    } else {
      waitForItemReady(currentItem, timeout: 10.0) { [weak self] ready in
        if ready {
          self?.performSeekOnItem(currentItem, to: timestamp, shouldPlay: shouldPlay, completion: completion)
        } else {
          ATLog(.error, "OpenAccessPlayer: Item failed to become ready")
          completion?(false)
        }
      }
    }
  }
  
  private func performSeekOnItem(_ item: AVPlayerItem, to timestamp: TimeInterval, shouldPlay: Bool, completion: ((Bool) -> Void)?) {
    let seekTime = CMTime(seconds: timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    item.seek(to: seekTime) { success in
      if success {
        if shouldPlay {
          self.avQueuePlayer.play()
        }
        self.restorePlaybackRate()
        completion?(true)
      } else {
        completion?(false)
      }
    }
  }
  
  private func waitForItemReady(_ item: AVPlayerItem, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
    if item.status == .failed {
      ATLog(.error, "OpenAccessPlayer: Item already failed - \(item.error?.localizedDescription ?? "unknown")")
      completion(false)
      return
    }
    
    let timeoutWorkItem = DispatchWorkItem {
      ATLog(.warn, "OpenAccessPlayer: Item ready timeout after \(timeout)s")
      completion(false)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
    
    var observation: NSKeyValueObservation?
    observation = item.observe(\.status, options: [.new]) { [weak self] observedItem, change in
      guard self != nil else { return }
      
      if observedItem.status == .readyToPlay {
        timeoutWorkItem.cancel()
        observation?.invalidate()
        completion(true)
      } else if observedItem.status == .failed {
        ATLog(.error, "OpenAccessPlayer: Item load failed - \(observedItem.error?.localizedDescription ?? "unknown")")
        timeoutWorkItem.cancel()
        observation?.invalidate()
        completion(false)
      }
    }
  }

  func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
    guard let currentTrackPosition = currentTrackPosition,
          let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition)
    else {
      completion?(currentTrackPosition)
      return
    }

    let chapterDuration = currentChapter.duration ?? currentChapter.position.track.duration
    let chapterStartTimestamp = currentChapter.position.timestamp

    let offsetWithinChapter = value * chapterDuration
    let absoluteTimestamp = chapterStartTimestamp + offsetWithinChapter

    // BOUNDARY VALIDATION: Ensure we don't seek beyond chapter boundaries
    let maxTimestamp = chapterStartTimestamp + chapterDuration
    let trackDuration = currentChapter.position.track.duration
    let clampedTimestamp = min(absoluteTimestamp, min(maxTimestamp, trackDuration))

    let newPosition = TrackPosition(
      track: currentChapter.position.track,
      timestamp: clampedTimestamp,
      tracks: currentTrackPosition.tracks
    )

    // Use enhanced logging system
    logSeek(
      action: "SLIDER_DRAG",
      from: currentTrackPosition,
      to: newPosition,
      sliderValue: value,
      success: true
    )

    seekTo(position: newPosition, completion: completion)
  }

  public func navigateToPosition(
    _ position: TrackPosition,
    in items: [AVPlayerItem],
    completion: ((TrackPosition?) -> Void)?
  ) {
    guard let index = items.firstIndex(where: { $0.trackIdentifier == position.track.key }) else {
      completion?(nil)
      return
    }

    let shouldPlay = avQueuePlayer.rate > 0
    avQueuePlayer.pause()

    if avQueuePlayer.currentItem != items[index] {
      let currentIndex = items.firstIndex(where: { $0 == avQueuePlayer.currentItem }) ?? 0

      if index < currentIndex {
        rebuildPlayerQueueAndNavigate(to: position, shouldResumePlayback: false) { _ in
          completion?(position)
        }
      } else {
        for _ in currentIndex..<index {
          avQueuePlayer.advanceToNextItem()
        }
      }
    }

    let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    avQueuePlayer.seek(to: seekTime) { success in
      if success && shouldPlay {
        self.avQueuePlayer.play()
      }
      self.restorePlaybackRate()

      DispatchQueue.main.async {
        completion?(success ? position : nil)
      }
    }
  }

  public func restorePlaybackRate() {
    avQueuePlayer.rate = PlaybackRate.convert(rate: playbackRate)
  }

  public func handlePlaybackEnd(currentTrack _: any Track, completion: ((TrackPosition?) -> Void)?) {
<<<<<<< HEAD
=======
    ATLog(.warn, "⚠️🔄 [OpenAccessPlayer] handlePlaybackEnd CALLED - will reset to beginning!")
    
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
    guard let currentTrackPosition, let firstTrack = currentTrackPosition.tracks.first else {
      completion?(nil)
      return
    }
    
    let beginningPosition = TrackPosition(
      track: firstTrack,
      timestamp: 0.0,
      tracks: currentTrackPosition.tracks
    )
    
    playbackStatePublisher.send(.bookCompleted)
    
    lastKnownPosition = beginningPosition
    
    DispatchQueue.main.async { [weak self] in
      self?.playbackStatePublisher.send(.stopped(beginningPosition))
    }
    
    avQueuePlayer.pause()
    
    completion?(beginningPosition)
  }

  /// Create a single player item from a track
  private func createPlayerItem(from track: any Track) -> AVPlayerItem? {
    if let fileStatus = assetFileStatus(track.downloadTask) {
      switch fileStatus {
      case let .saved(urls):
        guard let url = urls.first else {
          return nil
        }
        let playerItem = AVPlayerItem(url: url)
        playerItem.audioTimePitchAlgorithm = .timeDomain
        playerItem.trackIdentifier = track.key
        return playerItem
      case .missing, .unknown:
        break
      }
    }
    if let remote = track.urls?.first {
      // Use AVURLAsset with Authorization header for BiblioBoard/Blackstone streaming
      let asset: AVURLAsset
      if let token = bearerToken {
        let headers = ["Authorization": "Bearer \(token)"]
        let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        asset = AVURLAsset(url: remote, options: options)
      } else {
        asset = AVURLAsset(url: remote)
      }
      
      let playerItem = AVPlayerItem(asset: asset)
      playerItem.audioTimePitchAlgorithm = .timeDomain
      playerItem.trackIdentifier = track.key
      return playerItem
    }
    return nil
  }

  public func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
    var items = [AVPlayerItem]()
    for track in tracks {
      if let item = createPlayerItem(from: track) {
        items.append(item)
      } else {
        listenForDownloadCompletion(task: track.downloadTask)
      }
    }
    return items
  }

  public func addPlayerObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance()
    )

    avQueuePlayer.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
    avQueuePlayer.addObserver(self, forKeyPath: "rate", options: [.new, .old], context: nil)
    isObservingPlayerStatus = true
    
    // Add fast periodic time observer for UI updates (0.25s = 4 updates/second for smooth slider)
    addPeriodicTimeObserver()
  }
  
  private func addPeriodicTimeObserver() {
    // Remove existing observer if any
    if let token = timeObserverToken {
      avQueuePlayer.removeTimeObserver(token)
      timeObserverToken = nil
    }
    
    // 0.25 seconds = smooth UI updates without excessive overhead
    let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    
    timeObserverToken = avQueuePlayer.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { [weak self] time in
      guard let self = self,
            avQueuePlayer.rate > 0,  // Only emit while playing
            let position = currentTrackPosition
      else {
        return
      }
      positionSubject.send(position)
    }
  }

  func removePlayerObservers() {
    guard isObservingPlayerStatus else {
      return
    }
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    avQueuePlayer.removeObserver(self, forKeyPath: "status")
    avQueuePlayer.removeObserver(self, forKeyPath: "rate")
    isObservingPlayerStatus = false
    
    // Remove periodic time observer
    if let token = timeObserverToken {
      avQueuePlayer.removeTimeObserver(token)
      timeObserverToken = nil
    }
  }
}

extension OpenAccessPlayer {
  private func playbackBegan(trackPosition: TrackPosition) {
    playbackStatePublisher.send(.started(trackPosition))
  }

  private func playbackStopped(trackPosition: TrackPosition) {
    playbackStatePublisher.send(.stopped(trackPosition))
  }

  public func setupAudioSession() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance()
    )

    let session = AVAudioSession.sharedInstance()
    let configure: () -> Void = {
      do {
        if session.category != .playback || session.mode != .spokenAudio {
          try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        }
        if !session.isOtherAudioPlaying {
          try session.setActive(true, options: [])
        }
      } catch {
        ATLog(.error, "🔊 AudioSession setup failed: \(error)")
      }
    }

    if Thread.isMainThread {
      configure()
    } else {
      DispatchQueue.main.sync { configure() }
    }
  }

  override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change _: [NSKeyValueChangeKey: Any]?,
    context _: UnsafeMutableRawPointer?
  ) {
    if keyPath == "status", let player = object as? AVQueuePlayer {
      switch player.status {
      case .readyToPlay:
        playerIsReady = .readyToPlay
      case .failed:
        playerIsReady = .failed
      default:
        break
      }
    } else if keyPath == "rate", let player = object as? AVQueuePlayer {
      guard let rate = PlaybackRate(rawValue: Int(player.rate)) else {
        return
      }
      savePlaybackRate(rate: rate)
    }
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
      return
    }

    switch type {
    case .began:
      ATLog(.warn, "System audio interruption began.")
    case .ended:
      ATLog(.warn, "System audio interruption ended.")
      guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
        return
      }
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      if options.contains(.shouldResume) {
        play()
      }
    default: ()
    }
  }

  @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else {
      return
    }

    switch reason {
    case .newDeviceAvailable:
      let session = AVAudioSession.sharedInstance()
      for output in session.currentRoute.outputs {
        switch output.portType {
        case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
          play()
        default: ()
        }
      }
    case .oldDeviceUnavailable:
      if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
        for output in previousRoute.outputs {
          switch output.portType {
          case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
            pause()
          default: ()
          }
        }
      }
    default: ()
    }
  }

  public func performSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
    let epsilon: TimeInterval = 0.1
    let maxSafeTimestamp = position.track.duration - epsilon
    let safeTimestamp = min(position.timestamp, maxSafeTimestamp)

    if position.timestamp >= (position.track.duration - epsilon) &&
      tableOfContents.tracks.nextTrack(position.track) == nil
    {
      handlePlaybackEnd(currentTrack: position.track, completion: completion)
      return
    }

    let shouldPlay = avQueuePlayer.rate > 0
    avQueuePlayer.pause()

    let cmTime = CMTime(seconds: safeTimestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    avQueuePlayer.seek(to: cmTime) { [weak self] success in
      guard let self = self else {
        completion?(nil)
        return
      }
      
      if success {
        if shouldPlay {
          self.avQueuePlayer.play()
        }
        self.restorePlaybackRate()
        let actualPosition = TrackPosition(track: position.track, timestamp: safeTimestamp, tracks: position.tracks)
        completion?(actualPosition)
      } else {
        completion?(nil)
      }
    }
  }

  private func createPlayerItem(files: [URL]) -> AVPlayerItem? {
    guard files.count > 1 else {
      return AVPlayerItem(url: files[0])
    }

    let composition = AVMutableComposition()
    let compositionAudioTrack = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    )

    do {
      for (index, file) in files.enumerated() {
        let asset = AVAsset(url: file)
        if index == files.count - 1 {
          try compositionAudioTrack?.insertTimeRange(
            CMTimeRangeMake(start: .zero, duration: asset.duration),
            of: asset.tracks(withMediaType: .audio)[0],
            at: compositionAudioTrack?.asset?.duration ?? .zero
          )
        } else {
          try compositionAudioTrack?.insertTimeRange(
            CMTimeRangeMake(start: .zero, duration: asset.duration),
            of: asset.tracks(withMediaType: .audio)[0],
            at: compositionAudioTrack?.asset?.duration ?? .zero
          )
        }
      }
    } catch {
      ATLog(.error, "Player not yet ready. QueuedToPlay = true.")
      return nil
    }

    return AVPlayerItem(asset: composition)
  }

  @objc func playerItemDidReachEnd(_ notification: Notification) {
    guard let endedItem = notification.object as? AVPlayerItem,
          let endedTrackKey = endedItem.trackIdentifier,
          let endedTrack = tableOfContents.track(forKey: endedTrackKey)
    else {
      ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] Could not identify ended track")
      return
    }

    ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] Track ended - key=\(endedTrackKey), title=\(endedTrack.title ?? "nil"), duration=\(endedTrack.duration)")

    let endedPosition = TrackPosition(track: endedTrack, timestamp: endedTrack.duration, tracks: tableOfContents.tracks)
    let currentChapter = try? tableOfContents.chapter(forPosition: endedPosition)
    
    ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] Current chapter=\(currentChapter?.title ?? "nil")")

    // Check if next track is in the same chapter - if so, navigate explicitly
    if let nextTrack = tableOfContents.tracks.nextTrack(endedTrack) {
      let nextStart = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
      let nextChapter = try? tableOfContents.chapter(forPosition: nextStart)
      
      ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] Next track=\(nextTrack.title ?? "nil"), Next chapter=\(nextChapter?.title ?? "nil")")

      if let cur = currentChapter, let nxt = nextChapter, cur == nxt {
<<<<<<< HEAD
        // Same chapter continues on next track - navigate explicitly
        // CRITICAL: Don't use advanceToNextItem() - AVQueuePlayer's internal order
        // may not match our logical track order
=======
        ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] Same chapter - navigating to next track explicitly")
        // CRITICAL FIX: Don't use advanceToNextItem() - the AVQueuePlayer's internal order
        // may not match our logical track order. Always use explicit navigation.
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
        let wasPlaying = avQueuePlayer.rate > 0
        rebuildPlayerQueueAndNavigate(to: nextStart, shouldResumePlayback: wasPlaying)
        return
      }
    } else {
      ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] No next track found")
    }

    // Chapter completed - notify and move to next chapter
    if let completedChapter = currentChapter {
      ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] Chapter completed - \(completedChapter.title)")
      playbackStatePublisher.send(.completed(completedChapter))
    }

    if let curChapter = currentChapter {
      let nextChapter = tableOfContents.nextChapter(after: curChapter)
<<<<<<< HEAD
      
      if let nextChapter = nextChapter {
        play(at: nextChapter.position, completion: nil)
      } else {
=======
      ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] curChapter='\(curChapter.title)', nextChapter(after:)='\(nextChapter?.title ?? "NIL")'")
      
      if let nextChapter = nextChapter {
        ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] → Transitioning to '\(nextChapter.title)' at track=\(nextChapter.position.track.key), timestamp=\(nextChapter.position.timestamp)")
        play(at: nextChapter.position, completion: nil)
      } else {
        ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] → nextChapter is NIL - handling end of book")
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
        handlePlaybackEnd(currentTrack: endedTrack, completion: nil)
      }
    } else {
      ATLog(.warn, "🎵 [OpenAccess playerItemDidReachEnd] → currentChapter is NIL - handling end of book")
      handlePlaybackEnd(currentTrack: endedTrack, completion: nil)
    }
  }
}
