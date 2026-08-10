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
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    guard let audiobook = OpenAccessAudiobook(manifest: manifest, bookIdentifier: "audiobook-lifecycle-test", decryptor: nil, token: nil) else {
      throw XCTSkip("OpenAccessAudiobook failed to construct from alice_manifest — fixture problem, not a real failure.")
    }

    // Replace the real player with a controllable mock so we can drive
    // currentTrackPosition + isPlaying deterministically.
    let mockPlayer = PlayerMock(tableOfContents: audiobook.tableOfContents)
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
}
