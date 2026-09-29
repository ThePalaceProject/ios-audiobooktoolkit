//
//  AudiobookPlaybackModelTests.swift
//  PalaceAudiobookToolkitTests
//
//  Regression coverage for PP-4156 — download indicator visibility.
//

import XCTest
@testable import PalaceAudiobookToolkit

// Exercises @MainActor playback API; isolated to match.
@MainActor
final class AudiobookPlaybackModelTests: XCTestCase {
  // MARK: - PP-4156 — download-indicator visibility rule
  //
  // The download indicator must be visible whenever overall download progress is
  // less than 1.0, regardless of player type. A prior commit branched on
  // `audiobookManager.audiobook.player is LCPStreamingPlayer` and forced
  // `isDownloading = false` for LCP titles, which silently hid the indicator
  // while LCP tracks were decrypting in the background.
  //
  // The rule lives on AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress:),
  // a static function whose signature accepts only progress. Re-introducing player-type
  // branching would require changing the signature, which would fail this build.

  func test_shouldShowDownloadIndicator_isVisibleAtZeroProgress() {
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.0))
  }

  func test_shouldShowDownloadIndicator_isVisibleAtPartialProgress() {
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.01))
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.5))
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.999))
  }

  func test_shouldShowDownloadIndicator_isHiddenAtCompleteProgress() {
    XCTAssertFalse(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 1.0))
  }

  func test_shouldShowDownloadIndicator_isHiddenAboveCompleteProgress() {
    // Defensive: NetworkService now clamps to monotonic-max, but if a future change
    // ever published a value > 1, the indicator must remain hidden — not flicker on.
    XCTAssertFalse(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 1.5))
  }

  // MARK: - PP-4971 — remaining time is wall-clock, not book time
  //
  // `timeLeftInBook` is book time: how much recording is left. A listener at 2×
  // finishes a 60-minute remainder in 30 minutes, so the figure we SHOW must be
  // divided by the speed multiplier. Shipping book time told one reviewer hours
  // remained on a book they were about to finish.
  //
  // The rule lives on `remainingWallClock(bookTimeRemaining:rate:)`, a static
  // whose signature REQUIRES a rate — a caller cannot render remaining time
  // without supplying one, so the defect cannot be reintroduced by forgetting.

  func test_remainingWallClock_atNormalSpeed_isUnchanged() {
    XCTAssertEqual(
      AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 3600, rate: .normalTime),
      3600, accuracy: 0.001
    )
  }

  func test_remainingWallClock_atDoubleSpeed_isHalved() {
    XCTAssertEqual(
      AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 3600, rate: .doubleTime),
      1800, accuracy: 0.001
    )
  }

  func test_remainingWallClock_belowNormalSpeed_takesLonger() {
    // 0.75× — an hour of recording takes eighty minutes to hear.
    XCTAssertEqual(
      AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 3600, rate: .threeQuartersTime),
      4800, accuracy: 0.001
    )
  }

  func test_remainingWallClock_scalesAcrossTheEntireSpeedRail() {
    // PP-4518 extended the rail to 0.50×–3.00× in 0.05 steps. Every step must
    // divide, not just the six presets — a table test rather than three samples.
    for rate in PlaybackRate.allCases {
      let multiplier = Double(PlaybackRate.convert(rate: rate))
      XCTAssertEqual(
        AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 7200, rate: rate),
        7200 / multiplier, accuracy: 0.001,
        "rate \(rate.rawValue) did not scale the remaining time"
      )
    }
  }

  func test_remainingWallClock_finishedBookReadsZeroAtEverySpeed() {
    for rate in PlaybackRate.allCases {
      XCTAssertEqual(
        AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 0, rate: rate),
        0, accuracy: 0.001,
        "rate \(rate.rawValue) did not report a finished book as zero"
      )
    }
  }

  func test_remainingWallClock_rejectsNonFiniteAndNegativeInput() {
    // `timeLeftInBook` can go negative if the playhead overruns the manifest
    // duration, and non-finite if a track reports a bad duration. Neither may
    // reach the label as "-1 min remaining" or "nan".
    XCTAssertEqual(AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: .infinity, rate: .doubleTime), 0)
    XCTAssertEqual(AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: .nan, rate: .doubleTime), 0)
    XCTAssertEqual(AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: -60, rate: .doubleTime), 0)
  }

  // MARK: - PP-5205 — a chapter selection is not undone by the old playhead
  //
  // Choosing a chapter writes `currentLocation` immediately, and
  // `currentChapterTitle` reads it. But the item the patron is LEAVING keeps
  // emitting periodic positions while the seek settles, and every one of those
  // used to overwrite `currentLocation` — so the title snapped back to the
  // chapter just left, while the duration and remaining-time labels (which read
  // the PLAYER's position, and that already prefers the seek target) showed the
  // one chosen. Reported on build 509: "you land on the previous chapter and
  // then it switches."
  //
  // The rule is content-keyed, not timed: a seek that takes longer than the
  // skip-suppression window must still not be dragged backwards.

  func test_positionUpdateIsForNavigationTarget_withNoTargetAcceptsAnyTrack() {
    XCTAssertTrue(AudiobookPlaybackModel.positionUpdateIsForNavigationTarget(
      incomingTrackKey: "track-a", navigationTargetTrackKey: nil
    ), "with nothing in flight every position is authoritative")
  }

  func test_positionUpdateIsForNavigationTarget_acceptsTheTargetsOwnTrack() {
    XCTAssertTrue(AudiobookPlaybackModel.positionUpdateIsForNavigationTarget(
      incomingTrackKey: "track-b", navigationTargetTrackKey: "track-b"
    ), "the seek landing is exactly the position that must be shown")
  }

  func test_positionUpdateIsForNavigationTarget_rejectsTheTrackBeingLeft() {
    XCTAssertFalse(AudiobookPlaybackModel.positionUpdateIsForNavigationTarget(
      incomingTrackKey: "track-a", navigationTargetTrackKey: "track-b"
    ), "the old item's periodic tick must not move the display off the target")
  }

  /// End-to-end wiring: the gate is actually consulted by the fast-position
  /// subscription, and it releases once the target's own position arrives.
  ///
  /// The wait is deliberate. `selectedLocation` also opens the 1.5s skip
  /// suppression window, which would reject the foreign position on its own —
  /// so the assertion is made AFTER that window expires, where only the
  /// content-keyed hold can still be responsible. Without the hold this test
  /// fails: the foreign tick lands and `currentLocation` reverts to track A.
  ///
  /// `isLoaded = false` is load-bearing, not incidental. It routes the selection
  /// down the `pendingLocation` branch, so the mock never receives `play(at:)`,
  /// never reports `isPlaying`, and `DefaultAudiobookManager`'s 1-second
  /// now-playing poll therefore cannot re-publish the mock's static
  /// `currentTrackPosition` as a `.positionUpdated` in between the emits. With
  /// `isLoaded = true` that poll races every assertion here and the test measures
  /// the timer rather than the gate. The hold is armed BEFORE the branch, so the
  /// rule under test is identical on both.
  func test_chapterSelection_holdsDisplayedLocationAgainstTheTrackBeingLeft() async throws {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "pp5205-nav-hold", decryptor: nil, token: nil)
    )
    let player = PlayerMock(tableOfContents: audiobook.tableOfContents)
    player.isLoaded = false
    audiobook.player = player
    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Nav Hold", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    let model = AudiobookPlaybackModel(audiobookManager: manager)

    let tracks = audiobook.tableOfContents.allTracks
    let leavingTrack = try XCTUnwrap(tracks.first)
    let targetTrack = try XCTUnwrap(tracks.dropFirst().first)
    XCTAssertNotEqual(leavingTrack.key, targetTrack.key, "fixture must supply two distinct tracks")

    let allTracks = audiobook.tableOfContents.tracks
    model.selectedLocation = TrackPosition(track: targetTrack, timestamp: 0, tracks: allTracks)
    XCTAssertEqual(model.currentLocation?.track.key, targetTrack.key,
                   "the selection must be shown immediately")

    // Past the 1.5s skip-suppression window: only the content-keyed hold is left.
    try await Task.sleep(nanoseconds: 1_600_000_000)

    player._emitPosition(TrackPosition(track: leavingTrack, timestamp: 12, tracks: allTracks))
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(model.currentLocation?.track.key, targetTrack.key,
                   "a tick from the track being left must not move the display")

    // The seek lands: the target's own position is applied and the hold releases.
    player._emitPosition(TrackPosition(track: targetTrack, timestamp: 3, tracks: allTracks))
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(model.currentLocation?.track.key, targetTrack.key)
    XCTAssertEqual(model.currentLocation?.timestamp ?? -1, 3, accuracy: 0.001,
                   "the target's own position must be applied, not swallowed")

    // Hold released — an ordinary rollover to the next track is honoured again.
    player._emitPosition(TrackPosition(track: leavingTrack, timestamp: 42, tracks: allTracks))
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(model.currentLocation?.track.key, leavingTrack.key,
                   "the hold must not outlive the seek that set it")
  }

  /// PP-5205: the chapter NAME must move on the tap, not on the audio.
  ///
  /// `currentChapterTitle` derives from `currentLocation`, which `selectedLocation`
  /// writes synchronously — so the name is correct before any seek has been issued,
  /// let alone completed. The ios-core player mirrors this exact string onto the
  /// same tick as its chapter timecodes; it previously rendered a separate cache
  /// that only position events wrote, which left the name a seek behind the times
  /// printed beside it.
  func test_currentChapterTitle_followsASelectionImmediately() throws {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "pp5205-title", decryptor: nil, token: nil)
    )
    let player = PlayerMock(tableOfContents: audiobook.tableOfContents)
    player.isLoaded = false
    audiobook.player = player
    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Title Follows", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    let model = AudiobookPlaybackModel(audiobookManager: manager)

    let toc = audiobook.tableOfContents.toc
    let first = try XCTUnwrap(toc.first)
    let later = try XCTUnwrap(toc.dropFirst(2).first)
    XCTAssertNotEqual(first.title, later.title, "fixture must supply two distinctly-titled chapters")
    XCTAssertEqual(model.currentChapterTitle, first.title, "premise: the model starts on the first chapter")

    model.selectedLocation = later.position

    XCTAssertEqual(model.currentChapterTitle, later.title,
                   "the name must be the chapter the patron chose, with no seek having run yet")
    XCTAssertTrue(player.playAtCalls.isEmpty,
                  "premise: `isLoaded` is false, so nothing has been asked to play — the title moved on the tap alone")
  }
}

// MARK: - PP-4964 — the automatic save rides the playback clock

/// The automatic listening-position save used to be driven by
/// `DefaultAudiobookManager`'s main-runloop `Timer.publish`, re-throttled on
/// `RunLoop.main`. iOS coalesces and suspends that kind of timer during long
/// screen-locked playback, so a patron who locks the phone and listens untouched
/// is saved only by the lifecycle backstops. The save now subscribes to
/// `player.positionPublisher`, which every player feeds from its playback clock.
///
/// These tests never let the manager's timer produce a position: the mock player
/// reports `isPlaying == false`, so `setupNowPlayingInfoTimer`'s `compactMap`
/// yields nothing. Any save they observe came from the playback-clock stream.
/// Remove that subscription and `test_lockedListen_savesFromThePlaybackClockAlone`
/// records zero saves.
@MainActor
final class AudiobookPlaybackModelAutosaveTests: XCTestCase {
  private final class SpyBookmarkDelegate: AudiobookBookmarkDelegate {
    private(set) var savedPositions: [TrackPosition] = []
    func saveListeningPosition(at location: TrackPosition, completion: ((String?) -> Void)?) {
      savedPositions.append(location)
      completion?("server-id")
    }
    func saveBookmark(at location: TrackPosition, completion: ((TrackPosition?) -> Void)?) { completion?(nil) }
    func deleteBookmark(at location: TrackPosition, completion: ((Bool) -> Void)?) { completion?(false) }
    func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void) { completion([]) }
    func flushPendingOperations() {}
    func saveListeningPositionSync(at position: TrackPosition) { savedPositions.append(position) }
  }

  private struct Harness {
    let model: AudiobookPlaybackModel
    let player: PlayerMock
    let spy: SpyBookmarkDelegate
    let track: any Track
    let tracks: Tracks
    let clock: FakeUptime
  }

  private final class FakeUptime {
    var now: TimeInterval = 1_000
  }

  private func makeHarness() throws -> Harness {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "pp4964-autosave", decryptor: nil, token: nil)
    )
    let player = PlayerMock(tableOfContents: audiobook.tableOfContents)
    player.isLoaded = false
    player.isPlaying = false
    audiobook.player = player
    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Autosave", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    let spy = SpyBookmarkDelegate()
    manager.bookmarkDelegate = spy
    let model = AudiobookPlaybackModel(audiobookManager: manager)
    let clock = FakeUptime()
    model.uptime = { clock.now }
    let track = try XCTUnwrap(audiobook.tableOfContents.allTracks.first)
    return Harness(model: model, player: player, spy: spy, track: track,
                   tracks: audiobook.tableOfContents.tracks, clock: clock)
  }

  /// `positionPublisher` is delivered on the main queue; this returns once every
  /// block enqueued before it has run, so the sink has seen each emitted tick.
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  /// Emits a tick every 0.25s of playback (the periodic observer's cadence),
  /// advancing the monotonic clock in step. Drains after EACH tick: the sink
  /// reads the clock when it runs, so emitting a batch and draining once would
  /// deliver every tick at the batch's final time.
  private func play(_ h: Harness, from start: Double, seconds: Double) async {
    var t = start
    while t <= start + seconds {
      h.clock.now += 0.25
      h.player._emitPosition(TrackPosition(track: h.track, timestamp: t, tracks: h.tracks))
      await drainMainQueue()
      t += 0.25
    }
  }

  // MARK: Decision table

  func test_autosaveDecision_withNoBaseline_seedsWithoutWriting() throws {
    let h = try makeHarness()
    let candidate = TrackPosition(track: h.track, timestamp: 30, tracks: h.tracks)
    XCTAssertEqual(AudiobookPlaybackModel.autosaveDecision(since: nil, candidate: candidate, now: 5), .seed)
  }

  func test_autosaveDecision_insideTheInterval_waitsEvenAfterLargeMovement() throws {
    let h = try makeHarness()
    let mark = AudiobookPlaybackModel.AutosaveMark(
      position: TrackPosition(track: h.track, timestamp: 0, tracks: h.tracks), uptime: 100)
    let far = TrackPosition(track: h.track, timestamp: 300, tracks: h.tracks)
    let justInside = 100 + AudiobookPlaybackModel.autosaveInterval - 0.1
    XCTAssertEqual(AudiobookPlaybackModel.autosaveDecision(since: mark, candidate: far, now: justInside), .wait)
  }

  func test_autosaveDecision_atTheInterval_savesRealMovement() throws {
    let h = try makeHarness()
    let mark = AudiobookPlaybackModel.AutosaveMark(
      position: TrackPosition(track: h.track, timestamp: 10, tracks: h.tracks), uptime: 100)
    let moved = TrackPosition(track: h.track, timestamp: 25, tracks: h.tracks)
    let exactlyDue = 100 + AudiobookPlaybackModel.autosaveInterval
    XCTAssertEqual(AudiobookPlaybackModel.autosaveDecision(since: mark, candidate: moved, now: exactlyDue), .save)
  }

  func test_autosaveDecision_afterTheInterval_waitsWhenThePlayheadHasNotMoved() throws {
    let h = try makeHarness()
    let mark = AudiobookPlaybackModel.AutosaveMark(
      position: TrackPosition(track: h.track, timestamp: 10, tracks: h.tracks), uptime: 100)
    let barelyMoved = TrackPosition(track: h.track, timestamp: 11.5, tracks: h.tracks)
    XCTAssertEqual(AudiobookPlaybackModel.autosaveDecision(since: mark, candidate: barelyMoved, now: 160), .wait)
  }

  // MARK: Wiring

  func test_lockedListen_savesFromThePlaybackClockAlone() async throws {
    let h = try makeHarness()

    await play(h, from: 0, seconds: 180)

    // 180s at one save per 15s is 12 after the seeding tick. The bound matters in
    // both directions: zero is the defect, and more is a write cadence the host
    // pays for with a full registry rewrite each time.
    XCTAssertGreaterThanOrEqual(h.spy.savedPositions.count, 11,
      "three minutes of playback-clock ticks with no runloop timer must keep saving the position")
    XCTAssertLessThanOrEqual(h.spy.savedPositions.count, 12,
      "the save must be rate-limited to one write per interval, not one per tick")
    let last = try XCTUnwrap(h.spy.savedPositions.last)
    XCTAssertGreaterThanOrEqual(last.timestamp, 175,
      "the saved place must track the playhead, not the moment playback began")
  }

  func test_firstTick_isABaselineNotAWrite() async throws {
    let h = try makeHarness()

    await play(h, from: 600, seconds: 4)

    XCTAssertTrue(h.spy.savedPositions.isEmpty,
      "the first ticks after load must not write: a transient position there would replace the restored place")
  }

  func test_saveSuppression_holdsTheAutosaveOff() async throws {
    let h = try makeHarness()
    h.model.beginSaveSuppression(for: 600)

    await play(h, from: 0, seconds: 60)

    XCTAssertTrue(h.spy.savedPositions.isEmpty,
      "the restore window's suppression must also cover the playback-clock save")
  }

  /// A suppressed tick must not count as a write. If it moved the baseline,
  /// the first save after the window would slip another interval, and a
  /// suppression that outlasts playback would leave nothing saved at all.
  func test_saveSuppression_whenItLapses_theNextDueTickWrites() async throws {
    let h = try makeHarness()
    h.model.beginSaveSuppression(for: 0.4)

    await play(h, from: 0, seconds: 20)
    XCTAssertTrue(h.spy.savedPositions.isEmpty, "premise: the window covered the first ticks")

    // `suppressSavesUntil` is wall-clock, so the window has to lapse in real time.
    try await Task.sleep(nanoseconds: 500_000_000)
    await play(h, from: 20.25, seconds: 0.25)

    let saved = try XCTUnwrap(h.spy.savedPositions.first,
      "the first tick after the window is already due and must write")
    XCTAssertEqual(saved.timestamp, 20.25, accuracy: 0.001)
  }
}
