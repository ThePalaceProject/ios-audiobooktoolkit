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
