//
//  FindawayPlayer.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/31/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AudioEngine
import Combine
import UIKit

typealias EngineManipulation = () -> Void
typealias FindawayPlayheadManipulation = (previous: TrackPosition?, destination: TrackPosition)

// MARK: - PlayerState

/// `PlayerState`s help determine which methods to call
/// on the `FAEPlaybackEngine`. `PlayerState`s are set
/// by the public `play`/`skip`/`pause` methods defined
/// in the player interface.
///
/// The only method that ought to play or seek in a chapter
/// is `playWithCurrentState`, and it will check for the current
/// action and determine the way to handle its playback.
enum PlayerState {
  case none
  case queued(FindawayPlayheadManipulation)
  case play(FindawayPlayheadManipulation)
  case paused(TrackPosition)
}

// MARK: - FindawayPlayerError

enum FindawayPlayerError {
  case noAvailableTracks
}

// MARK: - FindawayPlayer

final class FindawayPlayer: NSObject, Player {
  var playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
  var queuesEvents: Bool = true
  var isDrmOk: Bool = true
  var tableOfContents: AudiobookTableOfContents
  var isLoaded: Bool = true
  var currentChapter: Chapter? {
    guard let currentTrackPosition else {
      return nil
    }

    return try? tableOfContents.chapter(forPosition: currentTrackPosition)
  }

  private var readyForPlayback: Bool = false
  private var queuedPlayerState: PlayerState = .none
  private let audioPlaybackRateIdentifierKey = "audioPlaybackRateKey"
  private var audioEngine = FAEAudioEngine.shared()
  private var cancellables: Set<AnyCancellable> = []

  // `queuedEngineManipulation` is a closure that will manipulate
  // `FAEPlaybackEngine`.
  //
  // The reason to queue a manipulation is that they are potentially
  // very expensive, so by performing fewer manipulations, we get
  // better performance and avoid crashes while in the background.
  private var queuedEngineManipulation: EngineManipulation?
  private var queuedManipulationWorkItem: DispatchWorkItem?
  private var manipulationSequenceNumber: Int = 0
  
  private var sliderSeekPosition: TrackPosition?

  // `shouldPauseWhenPlaybackResumes` handles a case in the
  // FAEPlaybackEngine where `pause`es that happen while
  // the book is not playing are ignored. So if we are
  // loading the next chapter for playback and a consumer
  // decides to pause, we will fail.
  //
  // This flag is used to show that we intend to pause
  // and it ought be checked when playback initiated
  // notifications come in from FAEPlaybackEngine.
  private var shouldPauseWhenPlaybackResumes = false
  private var willBeReadyToPerformPlayheadManipulation: Date = .init()
  private var debounceBufferTime: TimeInterval = 0.50
  private var pendingStartPosition: TrackPosition?

  private var sessionKey: String {
    tableOfContents.sessionKey ?? ""
  }

  private var licenseID: String {
    tableOfContents.licenseID ?? ""
  }

  private var audiobookID: String {
    tableOfContents.tracks.audiobookID
  }

  /// If no book is loaded, AudioEngine returns 0, so this is consistent with their behavior
  var currentOffset: Double {
    Double(audioEngine?.playbackEngine?.currentOffset ?? 0)
  }

  var isPlaying: Bool {
    audioEngine?.playbackEngine?.playerStatus == FAEPlayerStatus.playing
  }

  public var currentTrackPosition: TrackPosition? {
    if let seekPosition = sliderSeekPosition {
      return seekPosition
    }
    
    var position: TrackPosition?
    if let queuedPosition = queuedPlayhead() {
      position = queuedPosition
    } else {
      guard let currentChapter = audioEngine?.playbackEngine?.currentLoadedChapter(),
            let currentTrack = tableOfContents.tracks.track(
              forPart: Int(currentChapter.partNumber),
              sequence: Int(currentChapter.chapterNumber)
            )
      else {
        return nil
      }

      position = TrackPosition(
        track: currentTrack,
        timestamp: Double(currentOffset),
        tracks: tableOfContents.tracks
      )
    }

    return position
  }

  private var bookIsLoaded: Bool {
    guard audioEngine?.playbackEngine?.playerStatus != FAEPlayerStatus.unloaded else {
      return false
    }
    let chapter = audioEngine?.playbackEngine?.currentLoadedChapter()
    guard let loadedAudiobookID = chapter?.audiobookID else {
      return false
    }
    return loadedAudiobookID == audiobookID
  }

  private var eventHandler: FindawayPlaybackNotificationHandler
  private var queue = DispatchQueue(label: "org.nypl.labs.PalaceAudiobookToolkit.FindawayPlayer")

  convenience init?(tableOfContents: AudiobookTableOfContents) {
    guard let firstTrack = tableOfContents.allTracks.first else {
      return nil
    }

    self.init(
      currentPosition: TrackPosition(
        track: firstTrack,
        timestamp: 0,
        tracks: tableOfContents.tracks
      ),
      tableOfContents: tableOfContents
    )
  }

  public init(
    currentPosition: TrackPosition,
    tableOfContents: AudiobookTableOfContents,
    eventHandler: FindawayPlaybackNotificationHandler = DefaultFindawayPlaybackNotificationHandler(),
    databaseVerification: FindawayDatabaseVerification = FindawayDatabaseVerification.shared
  ) {
    isDrmOk = true
    isLoaded = true
    queuesEvents = true
    queuedPlayerState = .paused(currentPosition)

    self.eventHandler = eventHandler
    readyForPlayback = databaseVerification.verified
    self.tableOfContents = tableOfContents
    super.init()

    self.eventHandler.delegate = self
    databaseVerification.registerDelegate(self)
  }

  var playbackRate: PlaybackRate {
    get {
      let cachedValue = UserDefaults.standard.double(forKey: audioPlaybackRateIdentifierKey)
      guard cachedValue != 0 else {
        if let value = audioEngine?.playbackEngine?.currentRate {
          return PlaybackRate(rawValue: Int(value * 100))!
        } else {
          return .normalTime
        }
      }

      audioEngine?.playbackEngine?.currentRate = Float(cachedValue)
      return PlaybackRate(rawValue: Int(cachedValue * 100))!
    }

    set(newRate) {
      UserDefaults.standard.setValue(PlaybackRate.convert(rate: newRate), forKey: audioPlaybackRateIdentifierKey)
      queue.async(flags: .barrier) {
        ATLog(.debug, "FindawayPlayer: Setting playback rate to \(PlaybackRate.convert(rate: newRate))")
        self.audioEngine?.playbackEngine?.currentRate = PlaybackRate.convert(rate: newRate)
      }
    }
  }

  func play() {
    queue.async { [weak self] in
      guard let self = self, readyForPlayback else {
        ATLog(.error, "Player is not ready")
        return
      }
      performPlay()
    }
  }

  func pause() {
    queue.async { [weak self] in
      self?.performPause()
    }
  }

  func unload() {
    audioEngine?.playbackEngine?.unload()
    isLoaded = false
    playbackStatePublisher.send(.unloaded)
  }

  func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
    queue.async { [weak self] in
      guard let self = self, let currentTrackPosition = currentTrackPosition else {
        ATLog(.error, "Invalid chapter information required for skip.")
        DispatchQueue.main.async {
          completion?(nil)
        }
        return
      }

      let totalDuration = currentTrackPosition.track.duration
      let newTimestamp = currentTrackPosition.timestamp + timeInterval
      if newTimestamp >= 0 && newTimestamp <= totalDuration {
        let newPosition = TrackPosition(
          track: currentTrackPosition.track,
          timestamp: newTimestamp,
          tracks: currentTrackPosition.tracks
        )
        move(to: newPosition, completion: completion)
      } else {
        handleBeyondCurrentTrackSkip(
          newTimestamp: newTimestamp,
          currentTrackPosition: currentTrackPosition,
          completion: completion
        )
      }
    }
  }

  func handleBeyondCurrentTrackSkip(
    newTimestamp: Double,
    currentTrackPosition: TrackPosition,
    completion: ((TrackPosition?) -> Void)?
  ) {
    if newTimestamp > currentTrackPosition.track.duration {
      moveToNextTrackOrEnd(
        newTimestamp: newTimestamp,
        currentTrackPosition: currentTrackPosition,
        completion: completion
      )
    } else if newTimestamp < 0 {
      moveToPreviousTrackOrStart(
        newTimestamp: newTimestamp,
        currentTrackPosition: currentTrackPosition,
        completion: completion
      )
    } else {
      let newPosition = TrackPosition(
        track: currentTrackPosition.track,
        timestamp: max(0, newTimestamp),
        tracks: currentTrackPosition.tracks
      )
      move(to: newPosition, completion: completion)
    }
  }

  func moveToNextTrackOrEnd(
    newTimestamp: Double,
    currentTrackPosition: TrackPosition,
    completion: ((TrackPosition?) -> Void)?
  ) {
    var currentTrack = currentTrackPosition.track
    let overflowTime = newTimestamp - currentTrack.duration

    if let nextTrack = currentTrackPosition.tracks.nextTrack(currentTrack) {
      currentTrack = nextTrack
      let newPosition = TrackPosition(
        track: nextTrack,
        timestamp: overflowTime,
        tracks: currentTrackPosition.tracks
      )
      move(to: newPosition, completion: completion)
    } else {
      handlePlaybackEnd(currentTrack: currentTrack, completion: completion)
    }
  }

  func handlePlaybackEnd(currentTrack: any Track, completion: ((TrackPosition?) -> Void)?) {
    guard let currentTrackPosition else {
      completion?(nil)
      return
    }

    let endPosition = TrackPosition(
      track: currentTrack,
      timestamp: currentTrack.duration,
      tracks: currentTrackPosition.tracks
    )

    if let completedChapter = try? tableOfContents.chapter(forPosition: endPosition) {
      playbackStatePublisher.send(.completed(completedChapter))
    }

    pause()
    ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
    completion?(endPosition)
  }

  func moveToPreviousTrackOrStart(
    newTimestamp: Double,
    currentTrackPosition: TrackPosition,
    completion: ((TrackPosition?) -> Void)?
  ) {
    var adjustedTimestamp = newTimestamp
    var currentTrack = currentTrackPosition.track

    while adjustedTimestamp < 0,
          let previousTrack = currentTrackPosition.tracks.previousTrack(currentTrack)
    {
      currentTrack = previousTrack
      adjustedTimestamp += currentTrack.duration
    }

    adjustedTimestamp = max(0, min(adjustedTimestamp, currentTrack.duration))
    let newPosition = TrackPosition(
      track: currentTrack,
      timestamp: adjustedTimestamp,
      tracks: currentTrackPosition.tracks
    )

    move(to: newPosition, completion: completion)
  }

  func play(at position: TrackPosition, completion: ((Error?) -> Void)? = nil) {
    ATLog(.debug, "🎮 [FindawayPlayer] play(at:) CALLED - track=\(position.track.key), timestamp=\(position.timestamp)")
    queue.async { [weak self] in
      guard let self = self else {
        ATLog(.error, "🎮 [FindawayPlayer] play(at:) - self deallocated")
        completion?(NSError(
          domain: "PlayerError",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Player deallocated."]
        ))
        return
      }
      
      ATLog(.debug, "🎮 [FindawayPlayer] play(at:) - Creating manipulation, readyForPlayback=\(readyForPlayback)")
      
      // Set queued state directly to prevent race conditions with initial position
      let manipulation = createManipulation(position)
      pendingStartPosition = position
      queuedPlayerState = .play(manipulation)
      
      ATLog(.debug, "🎮 [FindawayPlayer] play(at:) - Set queuedPlayerState to .play, will call playWithCurrentState")
      
      if readyForPlayback {
        playWithCurrentState()
      } else {
        ATLog(.warn, "🎮 [FindawayPlayer] play(at:) - NOT ready for playback, state queued but not executing")
      }
      
      completion?(nil)
      ATLog(.debug, "🎮 [FindawayPlayer] play(at:) - Completion called")
    }
  }

  func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
    ATLog(.debug, "🎚️ [FindawayPlayer] move(to: \(value)) SLIDER SEEK CALLED")
    guard let currentTrackPosition = currentTrackPosition else {
      ATLog(.warn, "🎚️ [FindawayPlayer] move(to:) - No current track position")
      completion?(nil)
      return
    }
    let newTimestamp = value * currentTrackPosition.track.duration

    let trackPosition = TrackPosition(
      track: currentTrackPosition.track,
      timestamp: newTimestamp,
      tracks: currentTrackPosition.tracks
    )

    
    sliderSeekPosition = trackPosition
    
    move(to: trackPosition, completion: completion)
  }

  func move(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
    
    completion?(position)
    
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let manipulation = createManipulation(position)
      pendingStartPosition = position
      
      let wasPlaying = self.isPlaying
      self.queuedPlayerState = .play(manipulation)
      
      DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceBufferTime) { [weak self] in
        guard let self = self else { return }
        
        if !wasPlaying {
          self.shouldPauseWhenPlaybackResumes = true
        }
        
        self.playWithCurrentState()
      }
    }
  }

  private func queuedPlayhead() -> TrackPosition? {
    switch queuedPlayerState {
    case .none:
      nil
    case let .paused(position),
         let .queued((_, position)),
         let .play((_, position)):
      position
    }
  }

  private func performPlay() {
    switch queuedPlayerState {
    case .none:
      if var position = currentTrackPosition {
        position.timestamp = 0
        queuedPlayerState = .play((previous: nil, destination: position))
      }
    case let .queued(manipulation):
      queuedPlayerState = .play(manipulation)
    case .paused:
      fallthrough
    case .play:
      break
    }
    playWithCurrentState()
  }

  private func performPause() {
    guard let position = currentTrackPosition else {
      return
    }

    if isPlaying {
      queuedPlayerState = .paused(position)
      audioEngine?.playbackEngine?.pause()
      if let currentTrackPosition = currentTrackPosition {
        playbackStatePublisher.send(.stopped(currentTrackPosition))
      }
    } else {
      shouldPauseWhenPlaybackResumes = true
    }
  }

  private func performJumpToLocation(_ position: TrackPosition) {
    if readyForPlayback {
      queuedPlayerState = .play(createManipulation(position))
      playWithCurrentState()
    } else {
      queuedPlayerState = .play((previous: nil, destination: position))
    }
  }

  func createManipulation(_ position: TrackPosition) -> FindawayPlayheadManipulation {
    let playheadBeforeManipulation = currentTrackPosition
    return (previous: playheadBeforeManipulation, destination: position)
  }

  /// Method to determine which AudioEngine SDK should be called
  /// to move the playhead or resume playback.
  ///
  /// Not all playhead movement costs the same. In order to ensure snappy and consistent
  /// behavior from FAEPlaybackEngine, we must be careful about how many calls we make to
  /// `[FAEPlaybackEngine playForAudiobookID:partNumber:chapterNumber:offset:sessionKey:licenseID]`.
  /// Meanwhile, calls to `[FAEPlaybackEngine setCurrentOffset]` are cheap and can be made repeatedly.
  /// Because of this we must determine what kind of request we have received before proceeding.
  ///
  /// If moving the playhead stays in the same file, then the update is instant and we are still
  /// ready to get a new request.
  private func playWithCurrentState() {
    ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState CALLED - queuedPlayerState=\(queuedPlayerState)")
    
    func isSameTrackSeek(_ positionBeforeNavigation: TrackPosition?, _ destinationPosition: TrackPosition) -> Bool {
      guard let previous = positionBeforeNavigation else { 
        ATLog(.debug, "🎮 [FindawayPlayer] isSameTrackSeek: NO (no previous position)")
        return false 
      }
      // Check if we're seeking within the same track (cheap operation)
      let result = bookIsLoaded && isPlaying && previous.track.key == destinationPosition.track.key
      ATLog(.debug, "🎮 [FindawayPlayer] isSameTrackSeek: \(result) (bookIsLoaded=\(bookIsLoaded), isPlaying=\(isPlaying), sameTracks=\(previous.track.key == destinationPosition.track.key))")
      return result
    }

    /// We queue the playhead move in order to rate limit the expensive
    /// move operation.
    func enqueueEngineManipulation() {
      // Cancel any previously scheduled manipulation to prevent race conditions
      queuedManipulationWorkItem?.cancel()
      
      // Increment sequence number to invalidate any in-flight operations
      manipulationSequenceNumber += 1
      let currentSequence = manipulationSequenceNumber
      
      // Helper to reschedule without incrementing sequence number
      func rescheduleWithSameSequence() {
        let workItem = DispatchWorkItem { [weak self] in
          guard let self = self else { return }
          
          // Check if this operation is still valid (not superseded by a newer one)
          guard currentSequence == self.manipulationSequenceNumber else {
            return // This operation has been superseded, skip it
          }
          
          guard let manipulationClosure = self.queuedEngineManipulation else {
            return
          }
          
          if Date() < self.willBeReadyToPerformPlayheadManipulation {
            // Still too soon, reschedule with same sequence number
            rescheduleWithSameSequence()
          } else {
            // Execute the manipulation
            manipulationClosure()
            self.queuedEngineManipulation = nil
            self.queuedPlayerState = .none
            self.queuedManipulationWorkItem = nil
          }
        }
        
        self.queuedManipulationWorkItem = workItem
        self.queue.asyncAfter(deadline: self.dispatchDeadline(), execute: workItem)
      }
      
      // Start the scheduling chain
      rescheduleWithSameSequence()
    }

    func setAndQueueEngineManipulation(manipulationClosure: @escaping EngineManipulation) {
      willBeReadyToPerformPlayheadManipulation = Date().addingTimeInterval(debounceBufferTime)
      queuedEngineManipulation = manipulationClosure
      enqueueEngineManipulation()
    }

    switch queuedPlayerState {
    case .none:
      ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .none - no action")
      break
    case .queued((_, _)):
      ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .queued - no action")
      break
    case let .paused(position) where !bookIsLoaded:
      ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .paused (not loaded) - will load and play")
      setAndQueueEngineManipulation { [weak self] in
        self?.loadAndRequestPlayback(position)
      }
    case .paused:
      ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .paused (loaded) - will resume")
      setAndQueueEngineManipulation {
        self.audioEngine?.playbackEngine?.resume()
      }
    case let .play((previous, position)) where isSameTrackSeek(previous, position):
      // Same track seek - use cheap offset update to avoid unload/reload
      let wasPlaying = isPlaying
      let epsilon: Double = 0.1
      let maxSafe = max(0.0, position.track.duration - epsilon)
      let safeTimestamp = min(max(0.0, position.timestamp), maxSafe)
      ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .play (same track seek) - setting currentOffset to \(safeTimestamp)")

      // Update engine offset directly (cheap) and preserve play/pause state
      if let engine = audioEngine?.playbackEngine {
        engine.currentOffset = UInt(safeTimestamp)
      }

      // Remember where we intended to start for the next .started event
      pendingStartPosition = TrackPosition(
        track: position.track,
        timestamp: safeTimestamp,
        tracks: position.tracks
      )

      if !wasPlaying {
        // Keep paused after seek; clear pause-after-resume intent since no reload will occur
        shouldPauseWhenPlaybackResumes = false
      }

      // Clear slider seek preview shortly after applying offset so UI resumes normal updates
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.sliderSeekPosition = nil
      }

      queuedEngineManipulation = nil
      queuedPlayerState = .none
    case let .play((previous, position)):
      // Different track or initial load - need full playback with debounce
      if let prev = previous {
        ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .play (different track) - will debounce load. From: \(prev.track.key)@\(prev.timestamp) To: \(position.track.key)@\(position.timestamp)")
      } else {
        ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .play (initial load) - will debounce load. To: \(position.track.key)@\(position.timestamp)")
      }
      setAndQueueEngineManipulation { [weak self] in
        self?.loadAndRequestPlayback(position)
      }
    }
    
    ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState COMPLETED")
  }

  private func loadAndRequestPlayback(_ position: TrackPosition) {
    guard let track = position.track as? FindawayTrack else {
      ATLog(.error, "🎮 [FindawayPlayer] loadAndRequestPlayback - track is not FindawayTrack")
      return
    }
    
    guard let playbackEngine = audioEngine?.playbackEngine else {
      ATLog(.error, "🎮 [FindawayPlayer] loadAndRequestPlayback - playback engine is nil")
      return
    }
    
    guard !audiobookID.isEmpty, !sessionKey.isEmpty, !licenseID.isEmpty else {
      ATLog(.error, "🎮 [FindawayPlayer] loadAndRequestPlayback - missing required credentials")
      ATLog(.error, "  audiobookID: \(audiobookID.isEmpty ? "EMPTY" : "present")")
      ATLog(.error, "  sessionKey: \(sessionKey.isEmpty ? "EMPTY" : "present")")
      ATLog(.error, "  licenseID: \(licenseID.isEmpty ? "EMPTY" : "present")")
      return
    }

    ATLog(.debug, "🎮 [FindawayPlayer] 🚨 loadAndRequestPlayback - CALLING SDK play() - audiobookID=\(audiobookID), part=\(track.partNumber ?? 0), chapter=\(track.chapterNumber ?? 0), offset=\(UInt(position.timestamp))")
    ATLog(.debug, "🎮 [FindawayPlayer] 🚨 This will trigger FULL UNLOAD/RELOAD cycle in Findaway SDK")
    
    playbackEngine.play(
      forAudiobookID: audiobookID,
      partNumber: UInt(track.partNumber ?? 0),
      chapterNumber: UInt(track.chapterNumber ?? 0),
      offset: UInt(position.timestamp),
      sessionKey: sessionKey,
      licenseID: licenseID
    )
    
    ATLog(.debug, "🎮 [FindawayPlayer] loadAndRequestPlayback - SDK play() call completed")
  }

  private func dispatchDeadline() -> DispatchTime {
    DispatchTime.now() + debounceBufferTime
  }
}

// MARK: FindawayDatabaseVerificationDelegate

extension FindawayPlayer: FindawayDatabaseVerificationDelegate {
  func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification) {
    func handleLifecycleManagerUpdate(hasBeenVerified: Bool) {
      readyForPlayback = hasBeenVerified
      playWithCurrentState()
    }

    queue.async {
      handleLifecycleManagerUpdate(hasBeenVerified: findawayDatabaseVerification.verified)
    }
  }
}

// MARK: FindawayPlaybackNotificationHandlerDelegate

extension FindawayPlayer: FindawayPlaybackNotificationHandlerDelegate {
  private func chapter(for findawayChapter: FAEChapterDescription) -> Chapter? {
    guard let track = tableOfContents.tracks.track(
      forPart: Int(findawayChapter.partNumber),
      sequence: Int(findawayChapter.chapterNumber)
    ) else {
      return nil
    }

    return try? tableOfContents.chapter(forPosition: TrackPosition(
      track: track,
      timestamp: 0.0,
      tracks: tableOfContents.tracks
    ))
  }

  func audioEnginePlaybackFinished(_: FindawayPlaybackNotificationHandler, for chapter: FAEChapterDescription) {
    guard let chapterAtEnd = self.chapter(for: chapter) else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.playbackStatePublisher.send(.completed(chapterAtEnd))
    }
  }

  func audioEnginePlaybackStarted(_: FindawayPlaybackNotificationHandler, for findawayChapter: FAEChapterDescription) {
    queue.async { [weak self] in
      guard let self = self else {
        return
      }

      if let currentChapter = chapter(for: findawayChapter) {
        if shouldPauseWhenPlaybackResumes {
          performPause()
        } else {
          let startPosition: TrackPosition = {
            if let target = self.pendingStartPosition,
               target.track.key == currentChapter.position.track.key {
              return target
            }
            return currentChapter.position
          }()

          self.pendingStartPosition = nil

          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sliderSeekPosition = nil
            if let self = self {
              self.playbackStatePublisher.send(.started(startPosition))
            }
          }
        }
      }
      shouldPauseWhenPlaybackResumes = false
    }
  }

  func audioEnginePlaybackPaused(_: FindawayPlaybackNotificationHandler, for findawayChapter: FAEChapterDescription) {
    sliderSeekPosition = nil
    
    if let currentTrackPosition = currentTrackPosition ?? chapter(for: findawayChapter)?.position {
      DispatchQueue.main.async { [weak self] () in
        self?.playbackStatePublisher.send(.stopped(currentTrackPosition))
      }

      queue.async(flags: .barrier) {
        switch self.queuedPlayerState {
        case .none:
          self.queuedPlayerState = .paused(currentTrackPosition)
        default:
          break
        }
      }
    }
  }

  func audioEnginePlaybackFailed(
    _: FindawayPlaybackNotificationHandler,
    withError error: NSError?,
    for chapter: FAEChapterDescription
  ) {
    sliderSeekPosition = nil
    
    ATLog(.error, "🚨 [FindawayPlayer] Playback failed for chapter - part: \(chapter.partNumber), chapter: \(chapter.chapterNumber)")
    if let error = error {
      ATLog(.error, "  Error: \(error.localizedDescription)")
      ATLog(.error, "  Domain: \(error.domain), Code: \(error.code)")
      ATLog(.error, "  UserInfo: \(error.userInfo)")
    }
    
    guard let locationOfError = self.chapter(for: chapter)?.position else {
      ATLog(.error, "  Unable to determine chapter position for error")
      // Still send failure event even if we can't determine position
      DispatchQueue.main.async {
        let errorToSend = error ?? NSError(
          domain: "com.palace.findaway",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Findaway playback failed for unknown chapter"]
        )
        self.playbackStatePublisher.send(.failed(nil, errorToSend))
      }
      return
    }
    
    DispatchQueue.main.async {
      self.playbackStatePublisher.send(.failed(locationOfError, error))
    }
  }

  func audioEngineAudiobookCompleted(_: FindawayPlaybackNotificationHandler, for audiobookID: String) {
    if self.audiobookID == audiobookID {
      ATLog(.debug, "Findaway Audiobook did complete: \(audiobookID)")
      
      guard let firstTrack = tableOfContents.tracks.first else {
        return
      }
      
      let beginningPosition = TrackPosition(
        track: firstTrack,
        timestamp: 0.0,
        tracks: tableOfContents.tracks
      )
      
      playbackStatePublisher.send(.bookCompleted)
      
      DispatchQueue.main.async { [weak self] in
        self?.playbackStatePublisher.send(.started(beginningPosition))
      }
              
      queue.async { [weak self] in
        guard let self else { return }
        
        shouldPauseWhenPlaybackResumes = true
        queuedPlayerState = .paused(beginningPosition)
        loadAndRequestPlayback(beginningPosition)
      }
    } else {
      ATLog(
        .error,
        "Invalid State: Completed Audiobook \(audiobookID) does not belong to this Player \(self.audiobookID)."
      )
    }
  }
}

extension AudiobookTableOfContents {
  var sessionKey: String? { manifest.metadata?.drmInformation?.sessionKey }
  var licenseID: String? { manifest.metadata?.drmInformation?.licenseID }
}
