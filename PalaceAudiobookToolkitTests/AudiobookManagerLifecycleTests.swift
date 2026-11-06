//
//  AudiobookManagerLifecycleTests.swift
//  PalaceAudiobookToolkitTests
//
//  Regression coverage for HelpSpot 17865 — Audiobook NowPlaying freeze on
//  background → foreground.
//
//  These tests pin two behaviors:
//  (1) didEnterBackgroundNotification must REBUILD the timer (so the lock-screen
//      MPNowPlayingInfoCenter writer keeps firing at the .background cadence)
//      — NOT cancel it outright as a prior commit did.
//  (2) didBecomeActiveNotification must NOT publish a stale cached position
//      ahead of the player's resumed clock — the slider would otherwise jump
//      forward by the suspend duration. Position publish is now deferred a tick
//      so the player can refresh its internal clock first.
//
//  The third behavior from the contract (UIApplication.beginBackgroundTask wrap
//  around the MPNowPlayingInfoCenter write at AudiobookManager.swift:~594) is
//  exercised indirectly: this target has no UIApplication shim, and the main
//  repo's NowPlayingCoordinatorBackgroundTests in ios-core covers the writer
//  side. Documented as skip below.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import MediaPlayer
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookManagerLifecycleTests: XCTestCase {

  // MARK: - Fixture helpers

  /// Builds a DefaultAudiobookManager from the `alice_manifest.json` test
  /// resource. Mirrors `AudiobookNavigationView`'s preview factory but in test
  /// scope so we exercise the real notification observers + timer machinery.
  private func makeManager() throws -> (DefaultAudiobookManager, PlayerMock) {
    try makeManager(playerType: PlayerMock.self)
  }

  private func makeManager<P: PlayerMock>(playerType: P.Type) throws -> (DefaultAudiobookManager, P) {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    guard let audiobook = OpenAccessAudiobook(manifest: manifest, bookIdentifier: "audiobook-lifecycle-test", decryptor: nil, token: nil) else {
      throw XCTSkip("OpenAccessAudiobook failed to construct from alice_manifest — fixture problem, not a real failure.")
    }

    // Replace the real player with a controllable mock so we can drive
    // currentTrackPosition + isPlaying deterministically.
    let mockPlayer = P(tableOfContents: audiobook.tableOfContents)
    setMockPlayer(mockPlayer, on: audiobook)

    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Lifecycle Test", authors: ["Author"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    return (manager, mockPlayer)
  }

  /// Overwrite the audiobook's `player` via reflection-friendly setter; the
  /// property is declared `var` on `Audiobook` so direct assignment works.
  private func setMockPlayer(_ mock: PlayerMock, on audiobook: Audiobook) {
    audiobook.player = mock
  }

  // MARK: - Test 1: didEnterBackgroundNotification rebuilds, does not cancel

  /// HelpSpot 17865 — When the app enters background, the lock-screen writer
  /// must keep running (at the .background 15s cadence). Prior to this fix
  /// the notification handler did `timer?.cancel(); timer = nil`, which
  /// stranded MPNowPlayingInfoCenter — patrons reported their lock-screen
  /// scrubber froze, and on resume the slider snapped forward.
  ///
  /// In a unit-test environment `UIApplication.shared.applicationState` is
  /// `.background` (XCTest runs headless), so the rebuild actually re-creates
  /// the timer at the 15s interval. We assert the timer is non-nil after the
  /// notification — i.e. that the cancel-and-leave-nil bug is gone.
  func testBackgroundNotification_rebuildsTimerAtBackgroundInterval() throws {
    let (manager, player) = try makeManager()
    player.isPlaying = true

    // Sanity: timer is alive after init.
    XCTAssertNotNil(manager.timer, "Timer should be set up on init.")

    // Act: post the lifecycle notification.
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

    // The notification handler is wired via Combine .sink which delivers
    // synchronously on the same queue when no scheduler is interposed, but
    // setupNowPlayingInfoTimer schedules a Timer.publish on .main. Give it
    // a runloop tick to settle.
    let settled = XCTestExpectation(description: "Background handler settled")
    DispatchQueue.main.async {
      settled.fulfill()
    }
    wait(for: [settled], timeout: 1.0)

    // Assert: timer was rebuilt, not nilled-out. Pre-fix this was nil.
    XCTAssertNotNil(
      manager.timer,
      "didEnterBackgroundNotification must REBUILD the timer (background interval), not cancel-and-leave-nil. HelpSpot 17865."
    )
  }

  // MARK: - Test 2: didBecomeActiveNotification defers position publish

  /// HelpSpot 17865 — When returning to foreground, immediately publishing
  /// `audiobook.player.currentTrackPosition` races a stale cached value
  /// against the player's resumed clock. Patrons see the slider jump forward
  /// by the suspend duration. The fix is to rebuild the timer first, defer a
  /// tick for the player to refresh, and only then publish the position.
  ///
  /// We model the "stale → fresh" race by configuring the mock player to
  /// return its cached (stale) position on the first read, then a refreshed
  /// position on the second read after a tick. We then assert that the FIRST
  /// `.positionUpdated` event the manager publishes carries the REFRESHED
  /// timestamp — i.e., the manager waited for the player to update before
  /// publishing.
  func testForegroundNotification_doesNotPublishStalePosition() throws {
    let (manager, player) = try makeManager()

    let firstTrack = manager.tableOfContents.allTracks.first
    XCTAssertNotNil(firstTrack, "Test fixture must have at least one track.")
    guard let track = firstTrack else { return }

    let stalePosition = TrackPosition(track: track, timestamp: 10.0, tracks: manager.tableOfContents.tracks)
    let freshPosition = TrackPosition(track: track, timestamp: 90.0, tracks: manager.tableOfContents.tracks)

    // Player returns stale position synchronously, then flips to fresh after
    // a main-queue tick. The notification handler must publish the FRESH one.
    player.currentTrackPosition = stalePosition
    DispatchQueue.main.async {
      player.currentTrackPosition = freshPosition
    }

    var receivedTimestamps: [Double] = []
    let received = XCTestExpectation(description: "Position published")
    let cancellable = manager.statePublisher.sink { state in
      if case let .positionUpdated(position) = state, let position = position {
        receivedTimestamps.append(position.timestamp)
        received.fulfill()
      }
    }
    defer { cancellable.cancel() }

    // Act: post foreground notification.
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

    wait(for: [received], timeout: 2.0)

    XCTAssertFalse(receivedTimestamps.isEmpty, "Expected at least one .positionUpdated.")
    XCTAssertEqual(
      receivedTimestamps.first,
      freshPosition.timestamp,
      "First published position on foreground must be the player's REFRESHED timestamp (\(freshPosition.timestamp)), not the stale cached one (\(stalePosition.timestamp)). HelpSpot 17865."
    )
  }

  // MARK: - Test 3: nowPlayingInfo write wrapped in beginBackgroundTask
  //
  // The contract calls for asserting that `MPNowPlayingInfoCenter.default()
  // .nowPlayingInfo = ...` is wrapped in a `beginBackgroundTask`/`endBackgroundTask`
  // envelope. This toolkit target does not have a UIApplication-style shim
  // (no protocol abstraction over `UIApplication.shared`), so introducing
  // one would expand scope beyond the bug fix. The wrapping IS done in
  // `updateNowPlayingInfo` per the contract, and the main-repo
  // `NowPlayingCoordinatorBackgroundTests` cover the writer-side equivalent
  // with an injectable seam. Marked as skip per contract guidance:
  //   "If the toolkit doesn't already have a UIApplication shim, document
  //    and skip this test in the toolkit — main-repo coverage compensates."
  func testNowPlayingInfoWrite_isWrappedInBackgroundTask() throws {
    throw XCTSkip("Skipped per contract: toolkit lacks UIApplication shim; main-repo NowPlayingCoordinatorBackgroundTests covers writer-side beginBackgroundTask discipline.")
  }

  // MARK: - Test 4: player positionPublisher drives the lock screen independently
  //
  // HelpSpot 17865 residual (Crashlytics code 403, "NowPlayingCoordinator dry
  // while isPlaying"): the wall-clock `timer` that refreshes MPNowPlayingInfoCenter
  // is a main-runloop `.common` timer. iOS coalesces/suspends it during long
  // screen-locked background playback, so the lock screen goes stale >30s and
  // the ios-core watchdog logs the dry-stream (~23k events through 3.2.3).
  //
  // The player's AVPlayer periodic-time observer (`positionPublisher`) is
  // OS-guaranteed to fire while audio is actually playing — including
  // backgrounded/locked — because it is driven by the playback clock, not the
  // runloop. This test pins that the manager ALSO drives the lock-screen writer
  // off `positionPublisher`, so a position emission refreshes now-playing even
  // when the wall-clock timer is not the source (the background case, modeled
  // here by cancelling `timer` before emitting).
  func testPositionPublisher_refreshesLockScreen_whenWallClockTimerSilent() throws {
    let (manager, player) = try makeManager()

    let firstTrack = manager.tableOfContents.allTracks.first
    XCTAssertNotNil(firstTrack, "Test fixture must have at least one track.")
    guard let track = firstTrack else { return }

    // Model the background case: the coalescible wall-clock timer is not firing,
    // so it cannot be the source of any lock-screen refresh.
    manager.timer?.cancel()

    // Clear the process-wide now-playing info so a non-nil read afterwards can
    // only have come from the heartbeat we are exercising.
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

    let position = TrackPosition(track: track, timestamp: 42.0, tracks: manager.tableOfContents.tracks)
    player.isPlaying = true
    player.currentTrackPosition = position

    // The heartbeat delivers on the main runloop; give it a tick to settle.
    let settled = XCTestExpectation(description: "Heartbeat settled")
    player._emitPosition(position)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 2.0)

    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
    XCTAssertNotNil(
      info,
      "positionPublisher emission while playing must refresh MPNowPlayingInfoCenter even with the wall-clock timer cancelled — the lock-screen heartbeat must not depend solely on the coalescible main-runloop timer. HelpSpot 17865 / code 403."
    )

    let expectedElapsed = (try? manager.tableOfContents.chapterOffset(for: position))
    if let expectedElapsed, let actualElapsed = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double {
      XCTAssertEqual(
        actualElapsed,
        expectedElapsed,
        accuracy: 0.001,
        "The refreshed lock-screen elapsed time must reflect the emitted position."
      )
    }
  }

  // MARK: - Test 5: the periodic timers read player state on the main thread

  /// The lock-screen and chapter-monitor timers read `isPlaying` and
  /// `currentTrackPosition` on the main thread, where that state is written (PP-5349).
  func testPeriodicTimers_readPlayerStateOnMainThread() throws {
    let (manager, player) = try makeManager(playerType: ThreadRecordingPlayerMock.self)
    guard let track = manager.tableOfContents.allTracks.first else {
      return XCTFail("Test fixture must have at least one track.")
    }
    player.isPlaying = true
    player.currentTrackPosition = TrackPosition(track: track, timestamp: 5.0, tracks: manager.tableOfContents.tracks)
    player.resetReads()

    // `.positionUpdated` comes from the lock-screen timer here (didBecomeActive
    // also sends it, but nothing posts that in this test). The timeout covers
    // the timer's background cadence of 15s.
    let published = XCTestExpectation(description: "Lock-screen timer published a position")
    published.assertForOverFulfill = false
    let cancellable = manager.statePublisher.sink { state in
      if case .positionUpdated = state { published.fulfill() }
    }
    defer { cancellable.cancel() }

    wait(for: [published], timeout: 25.0)

    // A lock-screen tick reads the player three times, so a fourth read means
    // the one-second chapter monitor also ran.
    let reads = player.reads
    XCTAssertGreaterThanOrEqual(reads.total, 4, "The timers did not read the player, so the thread check below proves nothing.")
    XCTAssertEqual(reads.offMain, 0, "\(reads.offMain) of \(reads.total) timer reads of player state ran off the main thread.")
  }
}

/// Records the thread each read of `isPlaying` / `currentTrackPosition` runs on.
/// The counters are lock-guarded because a read may arrive off the main thread.
final class ThreadRecordingPlayerMock: PlayerMock {
  private let lock = NSLock()
  private var total = 0
  private var offMain = 0

  var reads: (total: Int, offMain: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (total, offMain)
  }

  func resetReads() {
    lock.lock()
    defer { lock.unlock() }
    total = 0
    offMain = 0
  }

  private func recordRead() {
    lock.lock()
    defer { lock.unlock() }
    total += 1
    if !Thread.isMainThread { offMain += 1 }
  }

  override var isPlaying: Bool {
    get { recordRead(); return super.isPlaying }
    set { super.isPlaying = newValue }
  }

  override var currentTrackPosition: TrackPosition? {
    get { recordRead(); return super.currentTrackPosition }
    set { super.currentTrackPosition = newValue }
  }
}

// MARK: - Now Playing writer seam

/// A host that owns Now Playing sets `nowPlayingWriter` to nil; the toolkit
/// must then leave the system center alone so there is one writer.
@MainActor
final class AudiobookManagerNowPlayingWriterTests: XCTestCase {
  private var manager: DefaultAudiobookManager!
  private var player: PlayerMock!
  private var tracker: PlaybackTrackerSpy!

  override func setUpWithError() throws {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(OpenAccessAudiobook(manifest: manifest, bookIdentifier: "now-playing-writer", decryptor: nil, token: nil))
    player = PlayerMock(tableOfContents: audiobook.tableOfContents)
    audiobook.player = player
    tracker = PlaybackTrackerSpy()
    manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Writer Test", authors: ["Author"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks),
      playbackTrackerDelegate: tracker
    )
  }

  override func tearDown() {
    manager?.timer?.cancel()
    manager = nil
    player = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func position(_ timestamp: Double) throws -> TrackPosition {
    let track = try XCTUnwrap(manager.tableOfContents.allTracks.first)
    return TrackPosition(track: track, timestamp: timestamp, tracks: manager.tableOfContents.tracks)
  }

  private func settleMainQueue() {
    let settled = expectation(description: "main queue settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 2.0)
  }

  func testInjectedWriter_positionTick_receivesTheWrite_andSystemCenterIsUntouched() throws {
    let spy = NowPlayingWriterSpy()
    manager.nowPlayingWriter = spy
    MPNowPlayingInfoCenter.default().nowPlayingInfo = ["sentinel": true]
    player.isPlaying = true
    let tick = try position(42.0)
    player.currentTrackPosition = tick

    player._emitPosition(tick)
    settleMainQueue()

    XCTAssertEqual(spy.infoWrites.count, 1)
    let expectedElapsed = try manager.tableOfContents.chapterOffset(for: tick)
    let elapsed = try XCTUnwrap(spy.infoWrites.last??[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double)
    XCTAssertEqual(elapsed, expectedElapsed, accuracy: 0.001)
    XCTAssertEqual(spy.stateWrites, [.playing])
    XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?["sentinel"] as? Bool, true)
  }

  func testNilWriter_positionTickAndLifecycleEvents_neverWriteTheSystemCenter() throws {
    manager.nowPlayingWriter = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = ["sentinel": true]
    player.isPlaying = true
    let tick = try position(42.0)
    player.currentTrackPosition = tick

    player._emitPosition(tick)
    player.playbackStatePublisher.send(.started(tick))
    player.playbackStatePublisher.send(.stopped(tick))
    manager.updateNowPlayingInfo(tick)
    settleMainQueue()
    manager.unload()

    XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?["sentinel"] as? Bool, true)
    XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?.count, 1)
  }

  /// Entering a new chapter refreshes Now Playing within about a second,
  /// without waiting for the next position-driven heartbeat.
  func testChapterChange_whilePlaying_isWrittenWithoutAPositionTick() throws {
    let spy = NowPlayingWriterSpy()
    manager.nowPlayingWriter = spy
    player.isPlaying = true
    player.currentTrackPosition = try position(5.0)

    let written = expectation(description: "chapter monitor wrote Now Playing")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { written.fulfill() }
    wait(for: [written], timeout: 5.0)

    XCTAssertGreaterThanOrEqual(spy.infoWrites.count, 1)
  }

  /// The lock-screen timer rebuild on backgrounding also tells the time
  /// tracker that playback is running; that call must survive timer changes.
  func testBackgrounding_whilePlaying_reportsPlaybackStartedToTracker() throws {
    player.isPlaying = true
    let before = tracker.started

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    settleMainQueue()

    XCTAssertEqual(tracker.started, before + 1)
  }

  func testBackgrounding_whilePaused_doesNotReportPlaybackStarted() throws {
    player.isPlaying = false
    let before = tracker.started

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    settleMainQueue()

    XCTAssertEqual(tracker.started, before)
  }
}

final class NowPlayingWriterSpy: NowPlayingInfoWriting {
  private(set) var infoWrites: [[String: Any]?] = []
  private(set) var stateWrites: [MPNowPlayingPlaybackState] = []
  private var storedInfo: [String: Any]?
  private var storedState: MPNowPlayingPlaybackState = .unknown

  var nowPlayingInfo: [String: Any]? {
    get { storedInfo }
    set { storedInfo = newValue; infoWrites.append(newValue) }
  }

  var playbackState: MPNowPlayingPlaybackState {
    get { storedState }
    set { storedState = newValue; stateWrites.append(newValue) }
  }
}

final class PlaybackTrackerSpy: AudiobookPlaybackTrackerDelegate {
  private(set) var started = 0
  private(set) var stopped = 0
  func playbackStarted() { started += 1 }
  func playbackStopped() { stopped += 1 }
}

// MARK: - Playback snapshot

/// `playbackSnapshot` bundles the per-tick values; it must report exactly what
/// the separate getters report, so moving a consumer onto it changes nothing.
@MainActor
final class PlaybackSnapshotTests: XCTestCase {
  private func makeManager() throws -> (DefaultAudiobookManager, PlayerMock) {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(OpenAccessAudiobook(manifest: manifest, bookIdentifier: "snapshot", decryptor: nil, token: nil))
    let player = PlayerMock(tableOfContents: audiobook.tableOfContents)
    audiobook.player = player
    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Snapshot", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    manager.timer?.cancel()
    return (manager, player)
  }

  func testSnapshot_withChapterDuration_reportsChapterValues() throws {
    let (manager, player) = try makeManager()
    var chapter = manager.tableOfContents.toc[2]
    chapter.duration = 321
    player.currentChapter = chapter
    player.currentOffset = 12.5
    let position = TrackPosition(track: chapter.position.track, timestamp: 40, tracks: manager.tableOfContents.tracks)
    player.currentTrackPosition = position

    let snapshot = manager.playbackSnapshot

    XCTAssertEqual(snapshot.chapter?.id, chapter.id)
    XCTAssertEqual(snapshot.chapterOffset, 12.5)
    XCTAssertEqual(snapshot.chapterDuration, 321)
    XCTAssertEqual(snapshot.position?.timestamp, 40)
  }

  func testSnapshot_chapterWithoutDuration_fallsBackToCurrentDuration() throws {
    let (manager, player) = try makeManager()
    var chapter = manager.tableOfContents.toc[1]
    chapter.duration = nil
    player.currentChapter = chapter
    let track = try XCTUnwrap(manager.tableOfContents.allTracks.last)
    player.currentTrackPosition = TrackPosition(track: track, timestamp: 1, tracks: manager.tableOfContents.tracks)

    let snapshot = manager.playbackSnapshot

    XCTAssertEqual(snapshot.chapterDuration, manager.currentDuration)
    XCTAssertEqual(snapshot.chapterDuration, track.duration)
  }

  func testSnapshot_withoutChapterOrPosition_reportsZeroes() throws {
    let (manager, player) = try makeManager()
    player.currentChapter = nil
    player.currentTrackPosition = nil

    let snapshot = manager.playbackSnapshot

    XCTAssertNil(snapshot.chapter)
    XCTAssertNil(snapshot.position)
    XCTAssertEqual(snapshot.chapterDuration, 0)
    XCTAssertEqual(snapshot.chapterOffset, 0)
  }

  /// The slider's progress on a tick is the chapter offset over its duration.
  func testPositionTick_setsProgressToChapterOffsetOverDuration() throws {
    let (manager, player) = try makeManager()
    var chapter = manager.tableOfContents.toc[0]
    chapter.duration = 200
    player.currentChapter = chapter
    let model = AudiobookPlaybackModel(audiobookManager: manager)
    let tick = chapter.position + 50

    player._emitPosition(tick)
    let drained = expectation(description: "tick delivered")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)

    XCTAssertEqual(model.playbackProgress, 0.25, accuracy: 0.0001)
  }

  func testPositionTick_withZeroDuration_setsProgressToZero() throws {
    let (manager, player) = try makeManager()
    var chapter = manager.tableOfContents.toc[0]
    chapter.duration = 0
    player.currentChapter = chapter
    let model = AudiobookPlaybackModel(audiobookManager: manager)

    player._emitPosition(chapter.position + 50)
    let drained = expectation(description: "tick delivered")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)

    XCTAssertEqual(model.playbackProgress, 0)
  }
}
