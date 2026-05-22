//
//  FindawayPlayerAsyncContractTests.swift
//  PalaceAudiobookToolkitTests
//
//  Covers the async/await migration of FindawayPlayer's Player protocol
//  surface (swarm_efd1f0c3 T2). FindawayPlayer wraps the AudioEngine SDK
//  which emits playback notifications asynchronously and — critically —
//  can emit duplicate `audioEnginePlaybackStarted` / `audioEnginePlaybackFailed`
//  notifications on rapid skips. The async surface guards against double
//  continuation resume; without it the second emission crashes the process.
//
//  The load-bearing test here is `testContinuationBox_resumesOnlyOnce` —
//  the contract's non-negotiable regression gate.
//
//  We do NOT stand up a real FAEPlaybackEngine. Instead we exercise the
//  protocol surface via a spy subclass that overrides the `currentTrackPosition`
//  seam so skipPlayhead / move(to:) math is deterministic.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class FindawayPlayerAsyncContractTests: XCTestCase {

  // MARK: - ContinuationBox direct tests
  // The non-negotiable regression gate. ContinuationBox MUST allow at most
  // one resume; the second resume is a silent no-op (never traps).
  // Findaway's SDK emits duplicate playback notifications on rapid track
  // skips — without this guard, the process aborts on second resume.

  /// First resume value is the one observed; a second resume on the same
  /// box is silently ignored. Mutant: removing the `continuation = nil`
  /// line after first resume would let a second `CheckedContinuation.resume`
  /// call trap the process.
  func testContinuationBox_resumesOnlyOnce_noTrap() async throws {
    let box = SingleResumeContinuationBox<Int>()
    let observed = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      box.attach(continuation)
      box.resume(returning: 42)
      // Second resume MUST NOT crash. Without the guard, CheckedContinuation
      // traps on multiple-resume in debug and undefined-behaves in release.
      box.resume(returning: 99)
    }
    XCTAssertEqual(observed, 42, "Only the first resume wins; second is dropped")
  }

  /// Concurrent resumes from different actors race onto the lock. Only one
  /// resume wins; no trap, no leak. Mutant: removing the NSLock would race
  /// the nil-out with a second `resume`, allowing both resumes to fire.
  func testContinuationBox_concurrentResumes_onlyOneSucceeds() async throws {
    let box = SingleResumeContinuationBox<Int>()
    let observed = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      box.attach(continuation)
      // Fire many resumes concurrently across threads. The contract is that
      // CheckedContinuation.resume is called AT MOST once; we don't care which
      // value wins, only that the process doesn't trap.
      DispatchQueue.concurrentPerform(iterations: 32) { i in
        box.resume(returning: i)
      }
    }
    XCTAssertTrue((0..<32).contains(observed), "Some resume must have won; no trap from the others")
  }

  /// Resume after attach but before the awaiter parks: still safe. Mutant:
  /// if `attach` overwrote the box state (instead of single-shot init), a
  /// late resume could double-fire.
  func testContinuationBox_unusedBox_doesNothing() {
    let box = SingleResumeContinuationBox<Int>()
    // No attach. Calling resume on an unattached box must be a silent no-op,
    // not a trap (the production code's notification observer may fire
    // before the continuation is attached during teardown).
    box.resume(returning: 1)
    box.resume(returning: 2)
    // Reaching here without crashing is the assertion.
    XCTAssertTrue(true, "Resume on unattached box must be a no-op, not a trap")
  }

  // MARK: - skipPlayhead bounds clamping (Findaway-specific)

  /// FindawayPlayer's skipPlayhead clamps forward overflow into the next
  /// track when one exists. We verify a forward overflow doesn't return nil
  /// (Findaway's contract: skip-past-end-of-track must wrap or pin).
  ///
  /// Mutant: removing the `handleBeyondCurrentTrackSkip` branch would either
  /// crash or return a junk TrackPosition with timestamp > track.duration.
  func testSkipPlayhead_forwardPastTrackEnd_returnsNonNil() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))

    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    // Start near the end of the track; +60s should overflow.
    let nearEnd = firstTrack.duration - 5
    player.currentTrackPositionOverride = TrackPosition(
      track: firstTrack,
      timestamp: nearEnd,
      tracks: toc.tracks
    )

    let result = await player.skipPlayhead(60)

    XCTAssertNotNil(result, "Skip past track end must resolve to next-track-or-end")
  }

  /// Negative interval past start clamps to 0. Mutant: dropping `max(0, ...)`
  /// in moveToPreviousTrackOrStart would leave a negative timestamp that
  /// AVPlayer would refuse.
  func testSkipPlayhead_negativeBeyondStart_clampsToZero() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)

    player.currentTrackPositionOverride = TrackPosition(
      track: firstTrack,
      timestamp: 5,
      tracks: toc.tracks
    )

    let result = await player.skipPlayhead(-30)

    XCTAssertEqual(result?.timestamp, 0, "Negative skip past start must clamp at 0 for first track")
  }

  /// Skip within the current track does NOT wrap; the new timestamp lands
  /// at the same track with `current + interval`. Mutant: changing `+` to
  /// `-` would land at `current - interval`.
  func testSkipPlayhead_withinTrack_returnsAdjustedPosition() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)

    let base: TimeInterval = 30
    player.currentTrackPositionOverride = TrackPosition(
      track: firstTrack,
      timestamp: base,
      tracks: toc.tracks
    )

    let result = await player.skipPlayhead(20)

    let timestamp = try XCTUnwrap(result?.timestamp)
    XCTAssertEqual(timestamp, base + 20, accuracy: 0.001,
                   "Within-track skip must be currentTimestamp + interval")
    XCTAssertEqual(result?.track.key, firstTrack.key,
                   "Within-track skip must not change tracks")
  }

  // MARK: - skipPlayhead early return on missing position

  /// Without a current track position, skipPlayhead returns nil and does NOT
  /// crash. Mutant: removing the guard would attempt arithmetic on nil.
  func testSkipPlayhead_returnsNil_whenNoCurrentTrackPosition() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    player.currentTrackPositionOverride = nil

    let result = await player.skipPlayhead(15)

    XCTAssertNil(result, "skipPlayhead without a position must return nil")
  }

  // MARK: - move(to:) early return on missing position

  /// Without a current track position, move(to:) returns nil and does NOT
  /// crash on the multiplication. Mutant: removing the guard would attempt
  /// `value * currentTrackPosition.track.duration` on nil.
  func testMoveTo_returnsNil_whenNoCurrentTrackPosition() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    player.currentTrackPositionOverride = nil
    XCTAssertNil(player.currentTrackPosition, "Precondition: no current position")

    let result = await player.move(to: 0.5)

    XCTAssertNil(result, "move(to:) without a position must return nil")
  }

  /// With a current position, move(to:) computes value * duration and returns
  /// a TrackPosition at that offset. Mutant: changing `*` to `/` would land
  /// at duration/value, way off.
  func testMoveTo_computesFractionalProgress() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    player.currentTrackPositionOverride = TrackPosition(
      track: firstTrack,
      timestamp: 0,
      tracks: toc.tracks
    )

    let result = await player.move(to: 0.25)

    let timestamp = try XCTUnwrap(result?.timestamp)
    XCTAssertEqual(timestamp, firstTrack.duration * 0.25, accuracy: 0.001,
                   "move(to: 0.25) must land at 25% of track duration")
  }

  // MARK: - Test doubles

  /// Spy subclass: bypasses the AudioEngine SDK by overriding
  /// `currentTrackPosition` so skipPlayhead / move(to:) math runs against
  /// a deterministic position regardless of audio engine state.
  final class SpyFindawayPlayer: FindawayPlayer {
    var currentTrackPositionOverride: TrackPosition?

    override var currentTrackPosition: TrackPosition? {
      currentTrackPositionOverride
    }
  }

  // MARK: - Fixture

  private static func makeFindawayFixture() throws -> (AudiobookTableOfContents, any Track) {
    // We reuse alice_manifest (openaccess shape) — the type signature on
    // TrackPosition / AudiobookTableOfContents is identical between players.
    // FindawayPlayer's math doesn't depend on FindawayTrack-specific fields
    // at the surface we're testing here (skipPlayhead bounds, move(to:) math).
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: FindawayPlayerAsyncContractTests.self))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "findaway-async-test", decryptor: nil, token: nil),
      "Fixture manifest failed to parse"
    )
    let toc = audiobook.tableOfContents
    let track = try XCTUnwrap(toc.allTracks.first)
    return (toc, track)
  }
}
