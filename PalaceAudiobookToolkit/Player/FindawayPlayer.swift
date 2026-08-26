//
//  FindawayPlayer.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/31/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AudioEngine
import Combine
import Foundation
import UIKit

/// Main-actor isolated: a queued manipulation is stored in main-actor state and
/// executed from the main-actor scheduler, so saying so removes the whole
/// "concurrently-executed closure" question rather than answering it per site.
typealias EngineManipulation = @MainActor () -> Void
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

// MARK: - SingleResumeContinuationBox

/// Thread-safe single-resume guard around a `CheckedContinuation`. Findaway's
/// `FAEPlaybackEngine` emits duplicate `playbackStarted` / `playbackFailed`
/// notifications on rapid track skips. A naked `continuation.resume()` would
/// trap on the second emission. This box guarantees AT MOST one resume even
/// under concurrent notification delivery from the SDK's internal queues.
///
/// Lifecycle:
///   1. `attach(_:)` — install the continuation when the async wrapper kicks off.
///   2. `resume(returning:)` / `resume(throwing:)` — first call resumes the
///      continuation and nils out the slot; later calls are silent no-ops.
///
/// Marked `final` (no subclassing — value semantics are not desired here;
/// the lock + ref-typed continuation are the whole point).
/// `T: Sendable` because `resume(returning:)` hands the value across an
/// isolation boundary — the continuation is resumed from AudioEngine's
/// threads, not the caller's.
final class SingleResumeContinuationBox<T: Sendable> {
  private var continuation: CheckedContinuation<T, Never>?
  private let lock = NSLock()

  init() {}

  /// Install the continuation. Calling `attach` twice replaces the previous
  /// continuation (which is leaked — caller's responsibility to attach once).
  func attach(_ continuation: CheckedContinuation<T, Never>) {
    lock.lock()
    defer { lock.unlock() }
    self.continuation = continuation
  }

  /// Resume with `value`. First call wins; subsequent calls are silent no-ops.
  /// Safe to call from any thread.
  func resume(returning value: T) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(returning: value)
  }
}

/// Throwing variant. Same single-resume semantics; the type is `Void` because
/// the only async-throws Player surface (`play(at:)`) doesn't return a value.
final class SingleResumeThrowingContinuationBox {
  private var continuation: CheckedContinuation<Void, Error>?
  private let lock = NSLock()

  init() {}

  func attach(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    defer { lock.unlock() }
    self.continuation = continuation
  }

  func resume() {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume()
  }

  func resume(throwing error: Error) {
    lock.lock()
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume(throwing: error)
  }
}

// MARK: - FindawayEngineCommands

/// The AudioEngine calls worth keeping off the thread that draws, and the one
/// serial queue that orders them.
///
/// `FindawayPlayer` conforms to `Player`, which is `@MainActor`, so the player
/// has been main-actor isolated all along — the compiler inferred it and then
/// reported forty-two violations, because the player's whole state machine
/// ran on a private serial queue instead. That queue is gone; the main actor
/// serialises the state machine now, and it does so for the readers too, which
/// the queue never did (`isPlaying`, `currentOffset` and the position timer
/// always read from main while the writes happened elsewhere).
///
/// What the queue actually bought is named in the 2018 comment it arrived with:
/// `FAEPlaybackEngine` manipulations are "potentially very expensive". That
/// property is preserved, and preserved only here. Playback for this SDK cannot
/// be exercised outside a device with a fulfilled title, so the SDK keeps the
/// threading it has always had rather than gaining main-thread calls nobody can
/// measure.
///
/// Nothing non-Sendable crosses: every parameter is a value, and the engine is
/// re-fetched from its own singleton inside the block rather than captured from
/// a main-actor property.
enum FindawayEngineCommands {
  private static let queue = DispatchQueue(
    label: "org.nypl.labs.PalaceAudiobookToolkit.FindawayPlayer"
  )

  /// The expensive one: a full unload/reload cycle inside the SDK.
  static func load(
    audiobookID: String,
    partNumber: UInt,
    chapterNumber: UInt,
    offset: UInt,
    sessionKey: String,
    licenseID: String
  ) {
    queue.async {
      FAEAudioEngine.shared()?.playbackEngine?.play(
        forAudiobookID: audiobookID,
        partNumber: partNumber,
        chapterNumber: chapterNumber,
        offset: offset,
        sessionKey: sessionKey,
        licenseID: licenseID
      )
    }
  }

  static func resume() {
    queue.async { FAEAudioEngine.shared()?.playbackEngine?.resume() }
  }

  static func pause() {
    queue.async { FAEAudioEngine.shared()?.playbackEngine?.pause() }
  }

  static func unload() {
    queue.async { FAEAudioEngine.shared()?.playbackEngine?.unload() }
  }

  /// Documented by the SDK as cheap, but ordered on the same queue as `load`
  /// on purpose: a seek that lands between a reload and its offset write must
  /// not be reordered around it.
  static func setOffset(_ offset: UInt) {
    queue.async { FAEAudioEngine.shared()?.playbackEngine?.currentOffset = offset }
  }

  static func setRate(_ rate: Float) {
    queue.async { FAEAudioEngine.shared()?.playbackEngine?.currentRate = rate }
  }
}

// MARK: - FindawayPlayer

/// Main-actor isolated explicitly. It was already isolated by its conformance
/// to `Player`; saying so out loud is what keeps a future reader from
/// reintroducing a background queue for the state machine. See
/// `FindawayEngineCommands` for the one thing that still runs off-main.
@MainActor
class FindawayPlayer: NSObject, Player {
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

  // MARK: - Fast UI Position Updates
  private let positionSubject = PassthroughSubject<TrackPosition, Never>()
  private var positionTimerCancellable: AnyCancellable?

  var positionPublisher: AnyPublisher<TrackPosition, Never> {
    positionSubject.eraseToAnyPublisher()
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

  // `isPlaybackDesired` tracks whether the USER intends playback to be active,
  // independent of the SDK's instantaneous `isPlaying` (FAEPlayerStatus.playing).
  // After a seek the SDK enters a buffer window where `isPlaying` is transiently
  // false; keying seek decisions off `isPlaying` then misclassifies same-track
  // skips as expensive cross-track reloads and pauses playback afterwards
  // (forcing the user to tap play again). Seek decisions key off this intent.
  private(set) var isPlaybackDesired = false
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

  required convenience init?(tableOfContents: AudiobookTableOfContents) {
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
    setupPositionTimer()
  }

  // MARK: - Fast UI Position Updates

  private func setupPositionTimer() {
    // Subscribe to playback state changes to start/stop the position timer
    playbackStatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self = self else { return }
        switch state {
        case .started:
          startPositionTimer()
        case .stopped, .completed, .bookCompleted, .unloaded, .failed:
          stopPositionTimer()
        }
      }
      .store(in: &cancellables)
  }

  private func startPositionTimer() {
    stopPositionTimer()

    // 0.25s interval for smooth UI updates
    positionTimerCancellable = Timer.publish(every: 0.25, on: .main, in: .common)
      .autoconnect()
      .compactMap { [weak self] _ -> TrackPosition? in
        guard let self = self, isPlaying else { return nil }
        return currentTrackPosition
      }
      .sink { [weak self] position in
        self?.positionSubject.send(position)
      }
  }

  private func stopPositionTimer() {
    positionTimerCancellable?.cancel()
    positionTimerCancellable = nil
  }

  var playbackRate: PlaybackRate {
    get {
      let cachedValue = UserDefaults.standard.double(forKey: audioPlaybackRateIdentifierKey)
      guard cachedValue != 0 else {
        if let value = audioEngine?.playbackEngine?.currentRate {
          // PP-4518: snap to the nearest enum step rather than force-unwrap —
          // the Findaway SDK may report a rate that has no exact case (and the
          // rail now spans 0.5×–3.0×, widening the chance of a mismatch).
          return PlaybackRate.nearest(to: value)
        } else {
          return .normalTime
        }
      }

      audioEngine?.playbackEngine?.currentRate = Float(cachedValue)
      return PlaybackRate.nearest(to: Float(cachedValue))
    }

    set(newRate) {
      UserDefaults.standard.setValue(PlaybackRate.convert(rate: newRate), forKey: audioPlaybackRateIdentifierKey)
      ATLog(.debug, "FindawayPlayer: Setting playback rate to \(PlaybackRate.convert(rate: newRate))")
      FindawayEngineCommands.setRate(PlaybackRate.convert(rate: newRate))
    }
  }

  func play() {
    guard readyForPlayback else {
      ATLog(.error, "Player is not ready")
      return
    }
    performPlay()
  }

  func pause() {
    performPause()
  }

  func unload() {
    isPlaybackDesired = false
    stopPositionTimer()
    FindawayEngineCommands.unload()
    isLoaded = false
    playbackStatePublisher.send(.unloaded)
  }

  // MARK: - Async Player protocol surface
  //
  // The Findaway SDK is callback-driven via NSNotification posts on
  // `FAEPlaybackChapterStarted` / `FAEPlaybackChapterFailed`. Bridging to
  // async/await requires:
  //   1. A continuation that resumes when the FIRST notification arrives.
  //   2. A single-resume guard — the SDK can emit duplicate notifications
  //      on rapid skips, which would trap a naked CheckedContinuation.
  //
  // `skipPlayhead` and `move(to:)` resume synchronously from the existing
  // internal seam because their resolution doesn't depend on SDK round-trips
  // (they compute target positions in app code; the SDK call is downstream
  // of the returned position via `move(to: TrackPosition, completion:)`).
  //
  // `play(at:)` resumes synchronously after queueing the SDK call because
  // the legacy completion-handler shape also returned at queue-time, not at
  // playback-confirmed-time. Preserving that contract avoids changing
  // observable timing for callers that immediately await `play(at:)` and
  // then read `currentTrackPosition` — they would deadlock if we waited for
  // the SDK notification (which may never come if Findaway's queue is
  // still draining from a prior request).

  func skipPlayhead(_ timeInterval: TimeInterval) async -> TrackPosition? {
    await withCheckedContinuation { (continuation: CheckedContinuation<TrackPosition?, Never>) in
      let box = SingleResumeContinuationBox<TrackPosition?>()
      box.attach(continuation)
      performSkipPlayhead(timeInterval) { result in
        box.resume(returning: result)
      }
    }
  }

  private func performSkipPlayhead(_ timeInterval: TimeInterval, completion: @escaping (TrackPosition?) -> Void) {
    guard let currentTrackPosition else {
      ATLog(.error, "Invalid chapter information required for skip.")
      completion(nil)
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
      moveToTrackPosition(newPosition, completion: completion)
    } else {
      handleBeyondCurrentTrackSkip(
        newTimestamp: newTimestamp,
        currentTrackPosition: currentTrackPosition,
        completion: completion
      )
    }
  }

  private func handleBeyondCurrentTrackSkip(
    newTimestamp: Double,
    currentTrackPosition: TrackPosition,
    completion: @escaping (TrackPosition?) -> Void
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
      moveToTrackPosition(newPosition, completion: completion)
    }
  }

  private func moveToNextTrackOrEnd(
    newTimestamp: Double,
    currentTrackPosition: TrackPosition,
    completion: @escaping (TrackPosition?) -> Void
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
      moveToTrackPosition(newPosition, completion: completion)
    } else {
      handlePlaybackEnd(currentTrack: currentTrack, completion: completion)
    }
  }

  private func handlePlaybackEnd(currentTrack: any Track, completion: @escaping (TrackPosition?) -> Void) {
    guard let currentTrackPosition else {
      completion(nil)
      return
    }

    let endPosition = TrackPosition(
      track: currentTrack,
      timestamp: currentTrack.duration,
      tracks: currentTrackPosition.tracks
    )

    // Pinned to the pre-PP-4948 tie-break like the other five resolution sites
    // that feed `.completed`. Here it is provably a no-op: this branch runs only
    // when there is no next track, so `endPosition` is the end of the BOOK, and
    // the last chapter keeps the end tolerance under either tie-break. It is
    // pinned anyway, because a lone unpinned site reads as an oversight — and in
    // this case it twice WAS one: two reviewers had to point at it.
    if let completedChapter = try? tableOfContents.chapter(
      forPosition: endPosition, preferChapterEndingHere: true
    ) {
      playbackStatePublisher.send(.completed(completedChapter))
    }

    pause()
    ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
    completion(endPosition)
  }

  private func moveToPreviousTrackOrStart(
    newTimestamp: Double,
    currentTrackPosition: TrackPosition,
    completion: @escaping (TrackPosition?) -> Void
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

    moveToTrackPosition(newPosition, completion: completion)
  }

  func play(at position: TrackPosition) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let box = SingleResumeThrowingContinuationBox()
      box.attach(continuation)
      performPlayAt(position) { error in
        if let error = error {
          box.resume(throwing: error)
        } else {
          box.resume()
        }
      }
    }
  }

  private func performPlayAt(_ position: TrackPosition, completion: @escaping (Error?) -> Void) {
    ATLog(.debug, "🎮 [FindawayPlayer] play(at:) CALLED - track=\(position.track.key), timestamp=\(position.timestamp)")
    ATLog(.debug, "🎮 [FindawayPlayer] play(at:) - Creating manipulation, readyForPlayback=\(readyForPlayback)")

    // Set queued state directly to prevent race conditions with initial position
    isPlaybackDesired = true
    let manipulation = createManipulation(position)
    pendingStartPosition = position
    queuedPlayerState = .play(manipulation)

    ATLog(.debug, "🎮 [FindawayPlayer] play(at:) - Set queuedPlayerState to .play, will call playWithCurrentState")

    if readyForPlayback {
      playWithCurrentState()
    } else {
      ATLog(.debug, "FindawayPlayer: play(at:) - NOT ready for playback, state queued")
    }

    completion(nil)
    ATLog(.debug, "🎮 [FindawayPlayer] play(at:) - Completion called")
  }

  func move(to value: Double) async -> TrackPosition? {
    await withCheckedContinuation { (continuation: CheckedContinuation<TrackPosition?, Never>) in
      let box = SingleResumeContinuationBox<TrackPosition?>()
      box.attach(continuation)
      performMove(to: value) { result in
        box.resume(returning: result)
      }
    }
  }

  private func performMove(to value: Double, completion: @escaping (TrackPosition?) -> Void) {
    ATLog(.debug, "🎚️ [FindawayPlayer] move(to: \(value)) SLIDER SEEK CALLED")
    guard let currentTrackPosition = currentTrackPosition else {
      ATLog(.debug, "FindawayPlayer: move(to:) - No current track position")
      completion(nil)
      return
    }
    let newTimestamp = value * currentTrackPosition.track.duration

    let trackPosition = TrackPosition(
      track: currentTrackPosition.track,
      timestamp: newTimestamp,
      tracks: currentTrackPosition.tracks
    )

    sliderSeekPosition = trackPosition

    moveToTrackPosition(trackPosition, completion: completion)
  }

  /// Internal helper that drives the FAEPlaybackEngine to a new target
  /// position. The completion fires immediately with the requested position
  /// — the SDK confirmation arrives later via the playback notification
  /// path. Callers that need post-confirmation state must subscribe to
  /// `playbackStatePublisher`.
  private func moveToTrackPosition(_ position: TrackPosition, completion: @escaping (TrackPosition?) -> Void) {
    completion(position)

    let manipulation = createManipulation(position)
    pendingStartPosition = position

    // Key the post-reload pause decision off the user's play INTENT, not the
    // SDK's transient `isPlaying` (false during the buffer window after the
    // prior seek). Otherwise a reload while the user is actively listening
    // ends paused, forcing them to tap play again.
    let pauseAfterReload = Self.shouldPauseAfterReload(playbackDesired: isPlaybackDesired)
    queuedPlayerState = .play(manipulation)

    // The seek state machine — `queuedPlayerState`, `pendingStartPosition`,
    // `shouldPauseWhenPlaybackResumes`, `isPlaybackDesired` — is mutated from a
    // single isolation domain, the main actor, serialised with the SDK
    // notification handlers that are now delivered there too. The delay is the
    // debounce and nothing else; it is the one part of the old queue hop that
    // was load-bearing.
    mainActorAfter(debounceBufferTime) { [weak self] in
      guard let self else { return }

      if pauseAfterReload {
        self.shouldPauseWhenPlaybackResumes = true
      }

      self.playWithCurrentState()
    }
  }

  /// Run `body` on the main actor after `delay` seconds.
  ///
  /// `DispatchQueue.main.asyncAfter` takes a `@Sendable` closure, which cannot
  /// capture this main-actor-isolated player. Delivery is on the main queue,
  /// which IS the main actor's executor, so asserting that is sound rather than
  /// merely convenient.
  private nonisolated func mainActorAfter(
    _ delay: TimeInterval,
    _ body: @escaping @MainActor @Sendable () -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated { body() }
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
    isPlaybackDesired = true
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
    isPlaybackDesired = false
    guard let position = currentTrackPosition else {
      return
    }

    if isPlaying {
      queuedPlayerState = .paused(position)
      FindawayEngineCommands.pause()
      if let currentTrackPosition = currentTrackPosition {
        playbackStatePublisher.send(.stopped(currentTrackPosition))
      }
    } else {
      shouldPauseWhenPlaybackResumes = true
    }
  }

  private func performJumpToLocation(_ position: TrackPosition) {
    isPlaybackDesired = true
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
      // Seeking within the same loaded track is a cheap `setCurrentOffset`,
      // valid whether or not the SDK is momentarily emitting audio. We must NOT
      // gate this on `isPlaying`: during the buffer window after a prior seek
      // `isPlaying` is transiently false, which would misroute a same-track skip
      // to the expensive unload/reload path (the audible stop→start).
      let sameTrackKey = previous.track.key == destinationPosition.track.key
      let result = Self.isSameTrackSeekDecision(bookIsLoaded: bookIsLoaded, isSameTrackKey: sameTrackKey)
      ATLog(.debug, "🎮 [FindawayPlayer] isSameTrackSeek: \(result) (bookIsLoaded=\(bookIsLoaded), sameTracks=\(sameTrackKey))")
      return result
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
        FindawayEngineCommands.resume()
      }
    case let .play((previous, position)) where isSameTrackSeek(previous, position):
      // Same track seek - use cheap offset update to avoid unload/reload
      let epsilon: Double = 0.1
      let maxSafe = max(0.0, position.track.duration - epsilon)
      let safeTimestamp = min(max(0.0, position.timestamp), maxSafe)
      ATLog(.debug, "🎮 [FindawayPlayer] playWithCurrentState: case .play (same track seek) - setting currentOffset to \(safeTimestamp)")

      // Update engine offset directly (cheap) and preserve play/pause state
      if audioEngine?.playbackEngine != nil {
        FindawayEngineCommands.setOffset(UInt(safeTimestamp))
      }

      // Remember where we intended to start for the next .started event
      pendingStartPosition = TrackPosition(
        track: position.track,
        timestamp: safeTimestamp,
        tracks: position.tracks
      )

      if isPlaybackDesired {
        // A same-track seek never reloads, so clear any stale pending-pause that
        // would otherwise stop playback the user intends to continue. When the
        // user intends to stay paused we leave the flag untouched.
        shouldPauseWhenPlaybackResumes = false
      }

      // Clear slider seek preview shortly after applying offset so UI resumes normal updates
      mainActorAfter(0.2) { [weak self] in
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

  /// We queue the playhead move in order to rate limit the expensive
  /// move operation.
  ///
  /// Lifted out of `playWithCurrentState` as a pair of methods rather than the
  /// nested functions they were: the reschedule chain hands itself to a
  /// `DispatchWorkItem`, whose body is `@Sendable`, and a local function cannot
  /// be captured there without becoming "concurrently-executed local function
  /// must be marked '@Sendable'". As methods on a main-actor type they are
  /// already isolated, and the recursion needs no capture at all. Behaviour is
  /// unchanged: same cancel, same sequence number, same deadline.
  private func setAndQueueEngineManipulation(manipulationClosure: @escaping EngineManipulation) {
    willBeReadyToPerformPlayheadManipulation = Date().addingTimeInterval(debounceBufferTime)
    queuedEngineManipulation = manipulationClosure
    enqueueEngineManipulation()
  }

  private func enqueueEngineManipulation() {
    // Cancel any previously scheduled manipulation to prevent race conditions
    queuedManipulationWorkItem?.cancel()

    // Increment sequence number to invalidate any in-flight operations
    manipulationSequenceNumber += 1
    scheduleManipulation(sequence: manipulationSequenceNumber)
  }

  /// Reschedule without incrementing the sequence number.
  private func scheduleManipulation(sequence currentSequence: Int) {
    let workItem = DispatchWorkItem { [weak self] in
      // The item is scheduled on the main queue, which IS the main actor's
      // executor, so the state it reads is in its own isolation domain.
      MainActor.assumeIsolated {
        guard let self else { return }

        // Check if this operation is still valid (not superseded by a newer one)
        guard currentSequence == self.manipulationSequenceNumber else {
          return // This operation has been superseded, skip it
        }

        guard let manipulationClosure = self.queuedEngineManipulation else {
          return
        }

        if Date() < self.willBeReadyToPerformPlayheadManipulation {
          // Still too soon, reschedule with same sequence number
          self.scheduleManipulation(sequence: currentSequence)
        } else {
          // Execute the manipulation
          manipulationClosure()
          self.queuedEngineManipulation = nil
          self.queuedPlayerState = .none
          self.queuedManipulationWorkItem = nil
        }
      }
    }

    queuedManipulationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: dispatchDeadline(), execute: workItem)
  }

  private func loadAndRequestPlayback(_ position: TrackPosition) {
    guard let track = position.track as? FindawayTrack else {
      ATLog(.error, "🎮 [FindawayPlayer] loadAndRequestPlayback - track is not FindawayTrack")
      return
    }

    guard audioEngine?.playbackEngine != nil else {
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

    FindawayEngineCommands.load(
      audiobookID: audiobookID,
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

  // MARK: - Pure seek-strategy decisions (unit-tested)
  //
  // Extracted so the seek routing is provable without standing up the
  // FAEPlaybackEngine SDK. These deliberately do NOT consult the SDK's
  // instantaneous `isPlaying` — that is the bug this fix removes.

  /// A seek that stays within the currently loaded track is the cheap
  /// `setCurrentOffset` path; everything else needs a full reload. Crucially
  /// independent of `isPlaying` so a same-track skip during the post-seek buffer
  /// window is not misrouted to the expensive unload/reload path.
  static func isSameTrackSeekDecision(bookIsLoaded: Bool, isSameTrackKey: Bool) -> Bool {
    bookIsLoaded && isSameTrackKey
  }

  /// After a reload, pause only when the user does NOT intend playback. Keying
  /// this off play-intent (not transient `isPlaying`) keeps a reload triggered
  /// while actively listening from ending paused.
  static func shouldPauseAfterReload(playbackDesired: Bool) -> Bool {
    !playbackDesired
  }
}

// MARK: FindawayDatabaseVerificationDelegate

extension FindawayPlayer: FindawayDatabaseVerificationDelegate {
  func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification) {
    readyForPlayback = findawayDatabaseVerification.verified
    playWithCurrentState()
  }
}

// MARK: FindawayPlaybackNotificationHandlerDelegate

extension FindawayPlayer: FindawayPlaybackNotificationHandlerDelegate {
  private func chapter(for findawayChapter: FindawayChapterRef) -> Chapter? {
    guard let track = tableOfContents.tracks.track(
      forPart: findawayChapter.partNumber,
      sequence: findawayChapter.chapterNumber
    ) else {
      return nil
    }

    // UNPINNED as of PP-4951. This asks "which chapter does the SDK's
    // notification refer to?", and the answer is the chapter that BEGINS at the
    // start of that part/sequence — not the one that ends there.
    //
    // The pin was PP-4948's status-quo hold, and it was wrong for every caller
    // of this helper. `timestamp: 0.0` on a Findaway part/sequence is exactly a
    // boundary position, so pinned it resolved to the PRECEDING chapter for 9 of
    // the 10 chapters of `secret_lives_manifest`. That fed three signals:
    //
    //   * `.completed`, where it named the chapter before the one that ended,
    //     and the handler then saved that chapter's start — a place the patron
    //     had finished two chapters ago.
    //   * `.started`, where it paired the previous chapter's TRACK with the
    //     current chapter's OFFSET, so the two halves of an announcement came
    //     from different chapters.
    //   * `.stopped`, the same way.
    //
    // Only the first chapter ever escaped, because it has no predecessor for the
    // boundary to be handed to.
    return try? tableOfContents.chapter(
      forPosition: TrackPosition(
        track: track,
        timestamp: 0.0,
        tracks: tableOfContents.tracks
      )
    )
  }

  func audioEnginePlaybackFinished(_: FindawayPlaybackNotificationHandler, for chapter: FindawayChapterRef) {
    guard let chapterAtEnd = self.chapter(for: chapter) else {
      return
    }
    playbackStatePublisher.send(.completed(chapterAtEnd))
  }

  func audioEnginePlaybackStarted(_: FindawayPlaybackNotificationHandler, for findawayChapter: FindawayChapterRef) {
    if let currentChapter = chapter(for: findawayChapter) {
      if shouldPauseWhenPlaybackResumes {
        performPause()
      } else {
        let startPosition: TrackPosition = {
          if let target = pendingStartPosition,
             target.track.key == currentChapter.position.track.key {
            return target
          }
          // Do NOT fall back to the chapter start (timestamp 0). On rapid
          // same-track skips the engine buffers→resumes repeatedly, firing
          // this notification after `pendingStartPosition` was already
          // consumed; emitting position 0 snaps the UI back to the start of
          // the book/chapter before the progress timer corrects it. Reflect
          // the engine's actual offset instead.
          return TrackPosition(
            track: currentChapter.position.track,
            timestamp: currentOffset,
            tracks: currentChapter.position.tracks
          )
        }()

        pendingStartPosition = nil

        mainActorAfter(0.05) { [weak self] in
          guard let self else { return }
          self.sliderSeekPosition = nil
          self.playbackStatePublisher.send(.started(startPosition))
        }
      }
    }
    shouldPauseWhenPlaybackResumes = false
  }

  func audioEnginePlaybackPaused(_: FindawayPlaybackNotificationHandler, for findawayChapter: FindawayChapterRef) {
    sliderSeekPosition = nil

    if let currentTrackPosition = currentTrackPosition ?? chapter(for: findawayChapter)?.position {
      playbackStatePublisher.send(.stopped(currentTrackPosition))

      // A genuine SDK pause (user pause already cleared intent via
      // performPause; reload-pauses too) means audio is stopped — keep
      // play-intent consistent so a later cross-track skip does not resume
      // playback the user did not ask for (e.g. after an audio interruption).
      isPlaybackDesired = false
      switch queuedPlayerState {
      case .none:
        queuedPlayerState = .paused(currentTrackPosition)
      default:
        break
      }
    }
  }

  func audioEnginePlaybackFailed(
    _: FindawayPlaybackNotificationHandler,
    withError error: NSError?,
    for chapter: FindawayChapterRef
  ) {
    sliderSeekPosition = nil
    // Playback stopped on error — drop play-intent so a retry/seek is not
    // treated as "user wants playback" and made to auto-resume.
    isPlaybackDesired = false

    ATLog(.error, "🚨 [FindawayPlayer] Playback failed for chapter - part: \(chapter.partNumber), chapter: \(chapter.chapterNumber)")
    if let error = error {
      ATLog(.error, "  Error: \(error.localizedDescription)")
      ATLog(.error, "  Domain: \(error.domain), Code: \(error.code)")
      ATLog(.error, "  UserInfo: \(error.userInfo)")
    }

    guard let locationOfError = self.chapter(for: chapter)?.position else {
      ATLog(.error, "  Unable to determine chapter position for error")
      // Still send failure event even if we can't determine position
      let errorToSend = error ?? NSError(
        domain: "com.palace.findaway",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Findaway playback failed for unknown chapter"]
      )
      playbackStatePublisher.send(.failed(nil, errorToSend))
      return
    }

    playbackStatePublisher.send(.failed(locationOfError, error))
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
      playbackStatePublisher.send(.started(beginningPosition))

      // Book finished: the user is no longer actively listening. Clear intent
      // so a later same-track scrub of the rewound-to-start book does not
      // resume audio against this pause.
      isPlaybackDesired = false
      shouldPauseWhenPlaybackResumes = true
      queuedPlayerState = .paused(beginningPosition)
      loadAndRequestPlayback(beginningPosition)
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
