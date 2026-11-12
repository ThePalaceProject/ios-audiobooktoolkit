//
//  AudiobookManagerLifecycleTests.swift
//  PalaceAudiobookToolkitTests
//
//  Regression coverage for HelpSpot 17865 — Audiobook NowPlaying freeze on
//  background → foreground.
//
//  Pins that a foreground return publishes the player's refreshed position,
//  and that the lock screen is refreshed from the player's position ticks,
//  which keep arriving while the screen is locked.
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
  /// scope so we exercise the real notification observers.
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

  // MARK: - Test 2: didBecomeActiveNotification defers position publish

  /// HelpSpot 17865 — When returning to foreground, immediately publishing
  /// `audiobook.player.currentTrackPosition` races a stale cached value
  /// against the player's resumed clock. Patrons see the slider jump forward
  /// by the suspend duration. The fix is to defer a
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

  // MARK: - Test 4: player positionPublisher drives the lock screen

  /// HelpSpot 17865: the lock screen is refreshed from the player's position
  /// ticks, which the playback clock keeps delivering while the screen is
  /// locked; main-runloop timers are coalesced there.
  func testPositionPublisher_refreshesLockScreen() throws {
    let (manager, player) = try makeManager()

    let firstTrack = manager.tableOfContents.allTracks.first
    XCTAssertNotNil(firstTrack, "Test fixture must have at least one track.")
    guard let track = firstTrack else { return }

    // A spy rather than the system center: the first system-center access in
    // a parallel test clone can take over ten seconds.
    let writer = NowPlayingWriterSpy()
    manager.nowPlayingWriter = writer

    let position = TrackPosition(track: track, timestamp: 42.0, tracks: manager.tableOfContents.tracks)
    player.isPlaying = true
    player.currentTrackPosition = position

    // Ticks are delivered on the main queue; let it drain.
    let settled = XCTestExpectation(description: "Tick delivered")
    player._emitPosition(position)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
    wait(for: [settled], timeout: 2.0)

    let info = try XCTUnwrap(
      writer.infoWrites.last ?? nil,
      "A position tick while playing must refresh Now Playing. HelpSpot 17865 / code 403."
    )
    let expectedElapsed = try manager.tableOfContents.chapterOffset(for: position)
    let actualElapsed = try XCTUnwrap(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double)
    XCTAssertEqual(actualElapsed, expectedElapsed, accuracy: 0.001,
                   "The refreshed lock-screen elapsed time must reflect the emitted position.")
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

  /// Backgrounding while playing tells the time tracker that playback is running.
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

// MARK: - One playback clock

/// The player's position ticks are the manager's only clock (PP-5504): each
/// tick resolves the chapter once, and Now Playing is written on a change a
/// patron can see or after a 10 s keep-alive, never on a timer.
@MainActor
final class PlaybackClockTests: XCTestCase {
  private var manager: DefaultAudiobookManager!
  private var player: PlayerMock!
  private var writer: NowPlayingWriterSpy!
  private var now: TimeInterval = 1_000
  private var lookups = 0

  override func setUp() async throws {
    try makeManager(playerType: PlayerMock.self)
  }

  override func tearDown() async throws {
    manager = nil
    player = nil
    writer = nil
  }

  private func makeManager<P: PlayerMock>(playerType: P.Type) throws {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(OpenAccessAudiobook(manifest: manifest, bookIdentifier: "playback-clock", decryptor: nil, token: nil))
    player = P(tableOfContents: audiobook.tableOfContents)
    audiobook.player = player
    manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Clock Test", authors: ["Author"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    writer = NowPlayingWriterSpy()
    manager.nowPlayingWriter = writer
    manager.uptime = { [unowned self] in now }
    manager.applicationState = { .active }
    let toc = manager.tableOfContents
    manager.resolveChapter = { [unowned self] position in
      lookups += 1
      return try? toc.chapter(forPosition: position)
    }
  }

  private func chapter(_ index: Int) -> Chapter {
    manager.tableOfContents.toc[index]
  }

  private func drainMainQueue() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  /// Player state events are delivered through `RunLoop.main`.
  private func settleRunLoop() {
    let settled = expectation(description: "run loop settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
    wait(for: [settled], timeout: 2)
  }

  /// Emits one tick at `position`, `at` seconds on the test clock.
  private func tick(_ position: TrackPosition, at time: TimeInterval) {
    now = time
    player._emitPosition(position)
    drainMainQueue()
  }

  private var writtenTitles: [String?] {
    writer.infoWrites.map { $0?[MPMediaItemPropertyTitle] as? String }
  }

  func testPositionTick_withWriter_resolvesTheChapterExactlyOncePerTick() {
    player.isPlaying = true
    let position = chapter(0).position + 1

    for second in 0..<5 {
      tick(position, at: 1_000 + Double(second) * 0.25)
    }

    XCTAssertEqual(lookups, 5)
  }

  /// A host that writes Now Playing itself pays for no chapter lookup per tick.
  func testPositionTick_withoutWriter_resolvesNoChapter() {
    manager.nowPlayingWriter = nil
    player.isPlaying = true

    tick(chapter(0).position + 1, at: 1_000)
    tick(chapter(0).position + 2, at: 1_001)

    XCTAssertEqual(lookups, 0)
  }

  func testChapterCrossing_whilePlaying_isWrittenOnTheTickThatCrossesIt() {
    player.isPlaying = true

    tick(chapter(0).position + 1, at: 1_000)
    tick(chapter(0).position + 2, at: 1_001)
    XCTAssertEqual(writtenTitles, [chapter(0).title])

    tick(chapter(1).position + 0.5, at: 1_002)

    XCTAssertEqual(writtenTitles, [chapter(0).title, chapter(1).title])
  }

  /// Steady playback at four ticks a second for 60 s: a write at the start and
  /// one per 10 s keep-alive, so seven in all.
  func testSteadyPlayback_writesOncePerKeepAliveInterval() {
    player.isPlaying = true
    let position = chapter(0).position + 1

    for index in 0...240 {
      tick(position, at: 1_000 + Double(index) * 0.25)
    }

    XCTAssertEqual(writer.infoWrites.count, 7)
  }

  func testRateChange_whilePlaying_isWrittenOnTheNextTick() throws {
    player.isPlaying = true
    tick(chapter(0).position + 1, at: 1_000)

    player.playbackRate = .doubleTime
    tick(chapter(0).position + 2, at: 1_001)

    XCTAssertEqual(writer.infoWrites.count, 2)
    let rate = try XCTUnwrap(writer.infoWrites.last??[MPNowPlayingInfoPropertyPlaybackRate] as? Double)
    XCTAssertEqual(rate, Double(PlaybackRate.convert(rate: .doubleTime)), accuracy: 0.001)
  }

  func testPauseThenPlay_eachWritesAtOnce() {
    player.isPlaying = true
    let position = chapter(0).position + 1
    tick(position, at: 1_000)

    player.isPlaying = false
    player.playbackStatePublisher.send(.stopped(position))
    settleRunLoop()
    player.isPlaying = true
    player.playbackStatePublisher.send(.started(position))
    settleRunLoop()

    XCTAssertEqual(writer.stateWrites, [.playing, .paused, .playing])
  }

  private var lastWrittenElapsed: Double? {
    writer.infoWrites.last??[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
  }

  /// `playAtPosition` starts playback, so it writes the new chapter as playing.
  func testPlayAtPosition_writesTheNewChapterAtOnce() {
    player.isPlaying = false
    let target = chapter(3).position + 4
    let done = expectation(description: "seek completed")

    manager.playAtPosition(target) { _ in done.fulfill() }
    wait(for: [done], timeout: 2)

    XCTAssertEqual(writtenTitles.last, chapter(3).title)
    XCTAssertEqual(writer.stateWrites.last, .playing)
  }

  /// A skip while paused produces no tick, so the skip itself writes.
  func testSkip_whilePaused_writesTheNewPositionAtOnce() throws {
    player.isPlaying = false
    player.skipPlayheadResult = .some(chapter(2).position + 3)
    let done = expectation(description: "skip completed")

    manager.skipPlayhead(30) { _ in done.fulfill() }
    wait(for: [done], timeout: 2)

    XCTAssertEqual(writtenTitles.last, chapter(2).title)
    XCTAssertEqual(try XCTUnwrap(lastWrittenElapsed), 3, accuracy: 0.001)
    XCTAssertEqual(writer.stateWrites.last, .paused)
  }

  /// The slider seek on players other than `OpenAccessPlayer` goes through
  /// `play(at:)`; its target is written at once.
  func testSeekWithSlider_otherPlayers_writesTheTargetAtOnce() throws {
    var target = chapter(2)
    target.duration = 200
    player.currentChapter = target
    let done = expectation(description: "seek completed")

    manager.seekWithSlider(value: 0.5) { _ in done.fulfill() }
    wait(for: [done], timeout: 2)

    XCTAssertEqual(writtenTitles.last, chapter(2).title)
    XCTAssertEqual(try XCTUnwrap(lastWrittenElapsed), 100, accuracy: 0.001)
  }

  func testSeekWithSlider_openAccessPlayer_whilePaused_writesAtOnce() throws {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(OpenAccessAudiobook(manifest: manifest, bookIdentifier: "slider-oa", decryptor: nil, token: nil))
    let toc = audiobook.tableOfContents
    let openAccess = SeekStubOpenAccessPlayer(tableOfContents: toc)
    let start = toc.toc[2].position
    openAccess.lastKnownPosition = start + 1
    openAccess.seekResult = start + 5
    audiobook.player = openAccess
    let oaManager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Slider", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: toc.allTracks)
    )
    let oaWriter = NowPlayingWriterSpy()
    oaManager.nowPlayingWriter = oaWriter
    let done = expectation(description: "seek completed")

    oaManager.seekWithSlider(value: 0.1) { _ in done.fulfill() }
    wait(for: [done], timeout: 2)

    let info = try XCTUnwrap(oaWriter.infoWrites.last ?? nil)
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, toc.toc[2].title)
    XCTAssertEqual(try XCTUnwrap(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double), 5, accuracy: 0.001)
    XCTAssertEqual(oaWriter.stateWrites.last, .paused)
  }

  /// A rate change from the lock screen or CarPlay writes without waiting for a tick.
  func testChangePlaybackRateCommand_writesWithoutATick() throws {
    player.isPlaying = false
    player.currentTrackPosition = chapter(1).position + 2

    manager.mediaControlPublisher.commandPublisher.send(.changePlaybackRate(2.0))

    XCTAssertEqual(writer.infoWrites.count, 1)
    let rate = try XCTUnwrap(writer.infoWrites.last??[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Float)
    XCTAssertEqual(rate, PlaybackRate.convert(rate: .doubleTime), accuracy: 0.001)
  }

  /// `.positionUpdated` keeps the cadence of the timer it replaced: once per
  /// 2 s of ticks while the app is active.
  func testPositionTicks_whilePlaying_publishPositionUpdatedOncePerInterval() {
    player.isPlaying = true
    var published = 0
    let cancellable = manager.statePublisher.sink { state in
      if case .positionUpdated = state { published += 1 }
    }
    defer { cancellable.cancel() }

    for index in 0...16 {
      tick(chapter(0).position + 1, at: 1_000 + Double(index) * 0.25)
    }

    XCTAssertEqual(published, 3)
  }

  func testPositionTicks_whilePaused_publishNoPositionUpdated() {
    player.isPlaying = false
    var published = 0
    let cancellable = manager.statePublisher.sink { state in
      if case .positionUpdated = state { published += 1 }
    }
    defer { cancellable.cancel() }

    tick(chapter(0).position + 1, at: 1_000)
    tick(chapter(0).position + 1, at: 1_003)

    XCTAssertEqual(published, 0)
  }

  /// With no ticks, nothing runs: no timer reads the player while it is paused.
  func testPaused_withoutTicks_nothingReadsThePlayer() throws {
    try makeManager(playerType: ThreadRecordingPlayerMock.self)
    let recorder = try XCTUnwrap(player as? ThreadRecordingPlayerMock)
    recorder.isPlaying = false
    // Let init-time download events, which read the player once, settle first.
    settleRunLoop()
    recorder.resetReads()

    let waited = expectation(description: "waited past the old timer intervals")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { waited.fulfill() }
    wait(for: [waited], timeout: 5)

    XCTAssertEqual(recorder.reads.total, 0)
    XCTAssertTrue(writer.infoWrites.isEmpty)
  }

  /// The snapshot's time left equals the duration less `chapterOffset(for:)`,
  /// the computation Now Playing used before, on every fixture.
  func testSnapshotTimeLeft_matchesChapterOffsetComputation_acrossFixtures() throws {
    for fixture in ManifestJSON.allCases {
      let manifest = try Manifest.from(jsonFileName: fixture.rawValue, bundle: Bundle(for: type(of: self)))
      guard let audiobook = OpenAccessAudiobook(manifest: manifest, bookIdentifier: "time-left-\(fixture.rawValue)", decryptor: nil, token: nil) else { continue }
      let fixtureManager = DefaultAudiobookManager(
        metadata: AudiobookMetadata(title: "Time Left", authors: ["A"]),
        audiobook: audiobook,
        networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
      )
      let toc = fixtureManager.tableOfContents
      for chapter in toc.toc {
        let duration = chapter.duration ?? chapter.position.track.duration
        for offset in [0, duration / 2, duration, duration + 100] {
          let position = TrackPosition(track: chapter.position.track, timestamp: chapter.position.timestamp + offset, tracks: toc.tracks)
          guard let resolved = try? toc.chapter(forPosition: position),
                let elapsed = try? toc.chapterOffset(for: position) else { continue }
          let expected = max((resolved.duration ?? position.track.duration) - elapsed, 0)

          let snapshot = fixtureManager.snapshot(for: position)

          XCTAssertEqual(snapshot.chapter?.id, resolved.id, "\(fixture.rawValue) '\(chapter.title)' +\(offset)")
          XCTAssertEqual(snapshot.timeLeft, expected, accuracy: 0.0001, "\(fixture.rawValue) '\(chapter.title)' +\(offset)")
        }
      }
    }
  }
}

/// Completes every seek at once with `seekResult`, without an AVQueuePlayer queue.
final class SeekStubOpenAccessPlayer: OpenAccessPlayer {
  var seekResult: TrackPosition?

  override public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
    completion?(seekResult)
  }

  override func configurePlayer() {}
  override func addPlayerObservers() {}
}

// MARK: - One chapter lookup per tick

/// Drives a production player's position from the test and sends its ticks.
@MainActor
protocol TickDrivenPlayer: Player {
  func move(to position: TrackPosition)
  func tick(_ position: TrackPosition)
}

/// The production open-access chapter and offset getters, fed by test ticks.
final class TickDrivenOpenAccessPlayer: OpenAccessPlayer, TickDrivenPlayer {
  private let ticks = PassthroughSubject<TrackPosition, Never>()
  override var positionPublisher: AnyPublisher<TrackPosition, Never> { ticks.eraseToAnyPublisher() }
  override func configurePlayer() {}
  override func addPlayerObservers() {}

  func move(to position: TrackPosition) { queuedTrackPosition = position }
  func tick(_ position: TrackPosition) {
    move(to: position)
    ticks.send(position)
  }
}

/// The LCP streaming player measured in PP-5504, with its own `currentOffset`.
final class TickDrivenLCPStreamingPlayer: LCPStreamingPlayer, TickDrivenPlayer {
  private let ticks = PassthroughSubject<TrackPosition, Never>()
  override var positionPublisher: AnyPublisher<TrackPosition, Never> { ticks.eraseToAnyPublisher() }
  override func configurePlayer() {}
  override func addPlayerObservers() {}
  override func removePlayerObservers() {}

  func move(to position: TrackPosition) { queuedTrackPosition = position }
  func tick(_ position: TrackPosition) {
    move(to: position)
    ticks.send(position)
  }
}

/// The production Findaway chapter getter over a playhead the test sets. The
/// playhead is overridden whole because the player starts with a queued pause
/// that only the AudioEngine clears.
final class TickDrivenFindawayPlayer: FindawayPlayer, TickDrivenPlayer {
  private let ticks = PassthroughSubject<TrackPosition, Never>()
  private var engineReading: TrackPosition?
  override var positionPublisher: AnyPublisher<TrackPosition, Never> { ticks.eraseToAnyPublisher() }
  override var currentTrackPosition: TrackPosition? { engineReading }

  func move(to position: TrackPosition) { engineReading = position }
  func tick(_ position: TrackPosition) {
    move(to: position)
    ticks.send(position)
  }
}

/// Every reader of one position tick — the manager, the playback model and the
/// values the Palace host reads from them — shares one chapter lookup (PP-5504).
@MainActor
final class OneChapterLookupPerTickTests: XCTestCase {
  private var manager: DefaultAudiobookManager!
  private var model: AudiobookPlaybackModel!
  private var player: (any TickDrivenPlayer)!

  override func tearDown() async throws {
    model = nil
    manager = nil
    player = nil
  }

  private enum PlayerKind { case openAccess, lcpStreaming, findaway }

  private func makeSession(_ kind: PlayerKind, nowPlayingWriter: NowPlayingInfoWriting? = nil) throws {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(OpenAccessAudiobook(manifest: manifest, bookIdentifier: "one-lookup", decryptor: nil, token: nil))
    switch kind {
    case .openAccess:
      player = TickDrivenOpenAccessPlayer(tableOfContents: audiobook.tableOfContents)
    case .lcpStreaming:
      player = TickDrivenLCPStreamingPlayer(tableOfContents: audiobook.tableOfContents, drmDecryptor: nil)
    case .findaway:
      player = TickDrivenFindawayPlayer(tableOfContents: audiobook.tableOfContents)
    }
    audiobook.player = player
    manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "One Lookup", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    manager.nowPlayingWriter = nowPlayingWriter
    model = AudiobookPlaybackModel(audiobookManager: manager, loadWatchTicks: { Empty().eraseToAnyPublisher() })
  }

  private var toc: AudiobookTableOfContents { manager.tableOfContents }
  private func chapter(_ index: Int) -> Chapter { toc.toc[index] }

  private func drainMainQueue() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  /// Sends a tick, lets every subscriber run, then reads what the Palace host
  /// reads on a tick: the presenter's chapter values and the session manager's
  /// snapshot. Returns the lookups the whole tick cost.
  @discardableResult
  private func tickAndReadLikeTheHost(_ position: TrackPosition) -> Int {
    let before = toc.chapterLookupCount
    player.tick(position)
    drainMainQueue()
    _ = model.chapterPlayheadOffset
    _ = model.chapterTimeLeft
    _ = model.currentChapterTitle
    _ = manager.playbackSnapshot
    return toc.chapterLookupCount - before
  }

  func testPositionTick_openAccess_hostReadsCostOneChapterLookup() throws {
    try makeSession(.openAccess)

    let costs = (1...5).map { tickAndReadLikeTheHost(chapter(1).position + Double($0)) }

    XCTAssertEqual(costs, [1, 1, 1, 1, 1])
  }

  func testPositionTick_lcpStreaming_hostReadsCostOneChapterLookup() throws {
    try makeSession(.lcpStreaming)

    let costs = (1...5).map { tickAndReadLikeTheHost(chapter(1).position + Double($0)) }

    XCTAssertEqual(costs, [1, 1, 1, 1, 1])
  }

  func testPositionTick_findaway_hostReadsCostOneChapterLookup() throws {
    try makeSession(.findaway)

    let costs = (1...5).map { tickAndReadLikeTheHost(chapter(1).position + Double($0)) }

    XCTAssertEqual(costs, [1, 1, 1, 1, 1])
  }

  /// A Findaway playhead that moves without a tick is read where it now is.
  func testFindaway_playheadMovesWithoutTick_currentChapterFollowsIt() throws {
    try makeSession(.findaway)
    tickAndReadLikeTheHost(chapter(1).position + 4)

    player.move(to: chapter(3).position + 2)

    XCTAssertEqual(manager.currentChapter?.id, chapter(3).id)
  }

  /// With the toolkit writing Now Playing, its own snapshot shares the lookup too.
  func testPositionTick_withNowPlayingWriter_stillCostsOneChapterLookup() throws {
    try makeSession(.lcpStreaming, nowPlayingWriter: NowPlayingWriterSpy())

    XCTAssertEqual(tickAndReadLikeTheHost(chapter(2).position + 3), 1)
  }

  /// A tick into the next chapter moves every reader to it.
  func testTickIntoNextChapter_everyReaderReportsTheNewChapter() throws {
    try makeSession(.lcpStreaming)
    tickAndReadLikeTheHost(chapter(1).position + 4)

    let next = chapter(2)
    tickAndReadLikeTheHost(next.position + 7)

    let duration = try XCTUnwrap(next.duration)
    XCTAssertEqual(model.currentChapterTitle, next.title)
    XCTAssertEqual(manager.currentChapter?.id, next.id)
    XCTAssertEqual(manager.playbackSnapshot.chapter?.id, next.id)
    XCTAssertEqual(model.chapterPlayheadOffset, 7, accuracy: 0.0001)
    XCTAssertEqual(model.chapterTimeLeft, duration - 7, accuracy: 0.0001)
    XCTAssertEqual(model.playbackProgress, 7 / duration, accuracy: 0.0001)
  }

  /// A seek moves the player without a tick; a read then follows the player,
  /// not the chapter the last tick resolved.
  func testSeekWithoutTick_readsFollowThePlayersNewPosition() throws {
    try makeSession(.openAccess)
    tickAndReadLikeTheHost(chapter(1).position + 4)

    let target = chapter(3)
    player.move(to: target.position + 2)

    XCTAssertEqual(manager.currentChapter?.id, target.id)
    XCTAssertEqual(manager.playbackSnapshot.chapter?.id, target.id)
    XCTAssertEqual(manager.currentOffset, 2, accuracy: 0.0001)
    XCTAssertEqual(manager.currentDuration, try XCTUnwrap(target.duration), accuracy: 0.0001)
  }

  /// Before any tick, a read resolves the player's position itself.
  func testReadBeforeAnyTick_resolvesThePlayersPosition() throws {
    try makeSession(.lcpStreaming)
    let target = chapter(4)

    player.move(to: target.position + 1)

    XCTAssertEqual(manager.currentChapter?.id, target.id)
    XCTAssertEqual(manager.playbackSnapshot.chapter?.id, target.id)
    XCTAssertEqual(manager.playbackSnapshot.chapterOffset, 1, accuracy: 0.0001)
  }

  /// A tick exactly on a boundary belongs to the chapter that begins there, for
  /// every reader, and the boundary still resolves to the chapter ending there
  /// for the `.completed` tie-break after the tick filled the memo.
  func testTickOnChapterBoundary_readersReportTheChapterThatBegins() throws {
    try makeSession(.lcpStreaming)
    let ending = chapter(2)
    let beginning = chapter(3)
    let boundary = beginning.position

    tickAndReadLikeTheHost(boundary)

    XCTAssertEqual(model.currentChapterTitle, beginning.title)
    XCTAssertEqual(manager.currentChapter?.id, beginning.id)
    XCTAssertEqual(model.chapterPlayheadOffset, 0, accuracy: 0.0001)
    XCTAssertEqual(try toc.chapter(forPosition: boundary, preferChapterEndingHere: true).id, ending.id)
  }
}
