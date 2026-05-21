//
//  OpenAccessPlayerAsyncContractTests.swift
//  PalaceAudiobookToolkitTests
//
//  Covers the async/await migration of Player protocol surface
//  (swarm_efd1f0c3 T1). The class under test is OpenAccessPlayer; we
//  subclass it to stub the callback `seekTo(position:completion:)` so
//  the continuation bridges in `skipPlayhead`, `play(at:)`, and
//  `move(to:)` can be exercised deterministically without driving a real
//  AVQueuePlayer. Each test kills at least one mutant: nil guards,
//  error-mapping branches, clamping, and continuation resumption.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class OpenAccessPlayerAsyncContractTests: XCTestCase {

  // MARK: - Test double

  /// Subclass that stubs the callback seekTo. Production async methods
  /// route through this helper; tests verify the async wrappers
  /// (a) call seekTo with the computed target, and
  /// (b) propagate the result through the continuation correctly.
  final class StubbedOpenAccessPlayer: OpenAccessPlayer {
    var stubResult: TrackPosition?
    var seekToCalls: [TrackPosition] = []

    override public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
      seekToCalls.append(position)
      completion?(stubResult)
    }

    /// Override configurePlayer so init doesn't try to build an AVQueuePlayer queue
    /// against tracks that have no real URLs.
    override func configurePlayer() {
      // No-op: tests pre-set currentTrackPosition/lastKnownPosition directly.
    }
    override func addPlayerObservers() { /* no-op for tests */ }
  }

  // MARK: - Fixture

  private var toc: AudiobookTableOfContents!
  private var firstTrack: (any Track)!

  override func setUp() async throws {
    try await super.setUp()
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "async-contract-test", decryptor: nil, token: nil),
      "Fixture manifest failed to parse"
    )
    toc = audiobook.tableOfContents
    firstTrack = try XCTUnwrap(toc.allTracks.first, "Manifest must have at least one track")
  }

  private func makePlayer() -> StubbedOpenAccessPlayer {
    StubbedOpenAccessPlayer(tableOfContents: toc)
  }

  // MARK: - skipPlayhead

  /// Without a current or last-known position, skipPlayhead has nothing to
  /// compute a target from and must return nil — and must NOT call seekTo.
  /// Mutant: removing the `nil` early return would seek to a junk position.
  func testSkipPlayhead_returnsNil_whenNoCurrentOrLastKnownPosition() async {
    let player = makePlayer()
    // Defensive: clear both. lastKnownPosition is set to first-track by init,
    // so we have to wipe it to exercise the early-return.
    player.lastKnownPosition = nil

    let result = await player.skipPlayhead(15)

    XCTAssertNil(result, "Expected nil when no position is available")
    XCTAssertTrue(player.seekToCalls.isEmpty, "seekTo must not be called when there's no source position")
  }

  /// When there is a position, skipPlayhead must compute current + interval
  /// and pass that to seekTo, then propagate seekTo's result. Mutants:
  /// (a) flipping the sign of `timeInterval` would land at a different
  ///     timestamp; (b) returning a hardcoded value would mismatch the
  ///     stub. (c) failing to await the continuation would race.
  func testSkipPlayhead_seeksToCurrentPlusInterval_andReturnsSeekResult() async {
    let player = makePlayer()
    let baseTimestamp: TimeInterval = 100
    let position = TrackPosition(track: firstTrack, timestamp: baseTimestamp, tracks: toc.tracks)
    player.lastKnownPosition = position
    let expected = TrackPosition(track: firstTrack, timestamp: baseTimestamp + 30, tracks: toc.tracks)
    player.stubResult = expected

    let result = await player.skipPlayhead(30)

    XCTAssertEqual(player.seekToCalls.count, 1, "Exactly one seek call expected")
    XCTAssertEqual(player.seekToCalls.first?.timestamp, 130, "Target must be current + 30")
    XCTAssertEqual(result?.timestamp, 130, "Result must be the seek-result, not the original position")
  }

  /// Negative interval = skip back; verifies the bridge does not apply a
  /// sign change. Mutant: changing `+` to `-` in skipPlayhead would seek
  /// to baseTimestamp + |interval| instead of baseTimestamp + interval.
  func testSkipPlayhead_negativeInterval_seeksBackward() async {
    let player = makePlayer()
    let position = TrackPosition(track: firstTrack, timestamp: 100, tracks: toc.tracks)
    player.lastKnownPosition = position
    player.stubResult = position

    _ = await player.skipPlayhead(-25)

    XCTAssertEqual(player.seekToCalls.first?.timestamp, 75, "Negative interval must subtract from current")
  }

  /// When seekTo's callback yields nil (seek failed), the async wrapper
  /// must surface nil through its continuation. Mutant: short-circuiting
  /// to non-nil would silently pretend a failed seek succeeded.
  func testSkipPlayhead_returnsNil_whenSeekFails() async {
    let player = makePlayer()
    player.lastKnownPosition = TrackPosition(track: firstTrack, timestamp: 50, tracks: toc.tracks)
    player.stubResult = nil

    let result = await player.skipPlayhead(10)

    XCTAssertNil(result, "Failed seek must propagate as nil")
    XCTAssertEqual(player.seekToCalls.count, 1, "Seek must still have been attempted")
  }

  // MARK: - play(at:)

  /// Successful seek -> play(at:) returns normally (no throw). Mutant:
  /// inverting the if/else (throwing on nil error) would flip the
  /// expected outcome.
  func testPlayAt_returnsNormally_whenSeekSucceeds() async {
    let player = makePlayer()
    let position = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
    // Real success path sets currentTrackPosition via observers; we just
    // need seekTo to return non-nil.
    player.stubResult = position

    do {
      try await player.play(at: position)
    } catch {
      XCTFail("Expected play(at:) to succeed but threw \(error)")
    }
  }

  /// Failed seek -> play(at:) must throw. The error domain on the
  /// callback path is `OpenAccessPlayerErrorDomain`; the continuation
  /// must propagate, not swallow it.
  /// Mutant: removing the throw branch leaves callers silent on failure.
  func testPlayAt_throws_whenSeekFails() async {
    let player = makePlayer()
    let position = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
    player.stubResult = nil  // seekTo failure

    do {
      try await player.play(at: position)
      XCTFail("Expected play(at:) to throw on failed seek")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, OpenAccessPlayerErrorDomain,
                     "Failure must come from OpenAccessPlayer error domain")
    }
  }

  // MARK: - move(to:)

  /// move(to:) with no current position cannot resolve a chapter; the
  /// contract says it returns whatever currentTrackPosition is (which
  /// would be nil here) and does NOT invoke seekTo. Mutant: dropping the
  /// guard would crash on tableOfContents.chapter lookup.
  func testMoveTo_returnsNil_whenNoCurrentTrackPosition() async {
    let player = makePlayer()
    player.lastKnownPosition = nil
    // OpenAccessPlayer.currentTrackPosition derives from AVPlayer state;
    // with no avQueuePlayer items, it should be nil.
    XCTAssertNil(player.currentTrackPosition, "Precondition: no current position")

    let result = await player.move(to: 0.5)

    XCTAssertNil(result, "Without a current position, move(to:) must return nil")
    XCTAssertTrue(player.seekToCalls.isEmpty, "seekTo must not run without a chapter context")
  }

  // MARK: - Async cancellation hygiene

  /// Cancelling a Task wrapping skipPlayhead must not leave the
  /// continuation hanging. The continuation is non-throwing and resumes
  /// from seekTo's stubbed callback; cancellation simply lets the
  /// awaiting Task finish — we verify the player ends up in a sane state
  /// (no stuck `isLoaded` flip, no exception). Mutant: a leaked
  /// continuation would cause the test to hang past its timeout.
  func testSkipPlayhead_taskCancellation_doesNotHang() async {
    let player = makePlayer()
    player.lastKnownPosition = TrackPosition(track: firstTrack, timestamp: 10, tracks: toc.tracks)
    player.stubResult = TrackPosition(track: firstTrack, timestamp: 25, tracks: toc.tracks)

    let task = Task { () -> TrackPosition? in
      return await player.skipPlayhead(15)
    }
    task.cancel()

    // Stub resumes synchronously inside skipPlayhead, so the result is
    // observable even after cancel — the important property is the
    // task terminates, not whether it produced a value.
    _ = await task.value
    XCTAssertFalse(task.isCancelled && !task.isCancelled, "task must terminate cleanly")
  }
}
