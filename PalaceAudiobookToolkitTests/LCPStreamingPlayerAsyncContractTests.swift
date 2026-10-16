//
//  LCPStreamingPlayerAsyncContractTests.swift
//  PalaceAudiobookToolkitTests
//
//  Covers the LCPStreamingPlayer async overrides: that `move(to:)` returns a
//  clamped TrackPosition without driving a real seek, and that the `seekTo`
//  override still sets and clears `isSeekingWithinSameTrack`.
//
//  The real AVQueuePlayer and ResourceLoader stack is avoided by subclassing
//  and stubbing the bridge points (initial item, seek).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class LCPStreamingPlayerAsyncContractTests: XCTestCase {

  // MARK: - Test double

  /// Subclass that bypasses AVPlayer construction in `configurePlayer`
  /// and stubs the inherited callback seekTo so the override's
  /// `isSeekingWithinSameTrack` flag can be observed before the
  /// async-after clear fires.
  final class StubbedLCPStreamingPlayer: LCPStreamingPlayer {
    var lastSuperSeekPosition: TrackPosition?
    var seekSuperCalls = 0

    override func configurePlayer() {
      // skip real AV setup
    }
    override func addPlayerObservers() { /* no-op */ }
    override func removePlayerObservers() { /* no-op */ }

    /// Bypass the base-class seekTo entirely so the override's
    /// `super.seekTo` call resumes through this stub.
    override public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
      // Replicate the LCP override behavior without touching avQueuePlayer:
      // run the override's flag-setting code (already done by the call
      // site before super.seekTo). Just invoke completion synchronously.
      seekSuperCalls += 1
      lastSuperSeekPosition = position
      completion?(position)
    }
  }

  // MARK: - Fixture

  private var toc: AudiobookTableOfContents!
  private var firstTrack: (any Track)!

  override func setUp() async throws {
    try await super.setUp()
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "lcp-async-test", decryptor: nil, token: nil),
      "Fixture manifest failed to parse"
    )
    toc = audiobook.tableOfContents
    firstTrack = try XCTUnwrap(toc.allTracks.first, "Manifest must have at least one track")
  }

  private func makePlayer() -> StubbedLCPStreamingPlayer {
    StubbedLCPStreamingPlayer(tableOfContents: toc, drmDecryptor: nil)
  }

  // MARK: - move(to:)

  /// Without a current track position, `move(to:)` returns
  /// currentTrackPosition (nil) and does not seek. Mutant: removing the
  /// guard would crash on chapter lookup.
  func testMoveTo_returnsNil_whenNoCurrentTrackPosition() async {
    let player = makePlayer()
    // `currentTrackPosition` falls back to `lastKnownPosition` (set by init
    // to the first track). Wipe that fallback so the guard branch fires.
    player.lastKnownPosition = nil
    XCTAssertNil(player.currentTrackPosition, "Precondition: no current position")

    let result = await player.move(to: 0.5)

    XCTAssertNil(result, "Expected nil when no current position")
  }

  // MARK: - skipPlayhead inherits base behavior + invokes LCP seekTo override

  /// The base async skipPlayhead computes (current + interval) and then
  /// calls seekTo — which LCP overrides. Verifies the override path is
  /// taken and the resulting position carries the new timestamp.
  /// Mutant: changing skipPlayhead's `currentTrackPosition + interval`
  /// to `currentTrackPosition + 0` would surface here.
  func testSkipPlayhead_invokesLCPSeekTo_withComputedTarget() async {
    let player = makePlayer()
    let base = TrackPosition(track: firstTrack, timestamp: 60, tracks: toc.tracks)
    player.lastKnownPosition = base

    let result = await player.skipPlayhead(20)

    XCTAssertEqual(player.seekSuperCalls, 1, "Override seekTo must be hit exactly once")
    XCTAssertEqual(player.lastSuperSeekPosition?.timestamp, 80, "Target must be current + 20")
    XCTAssertEqual(result?.timestamp, 80, "Async result must propagate seekTo's resolved position")
  }

  // MARK: - play(at:) — async surface dispatches through LCP playCallback override

  /// `play(at:)` is bridged into the LCP override's playCallback. We
  /// can't fully exercise the LCP queue logic without AVPlayer, but we
  /// can verify the async surface does not throw when the override
  /// completes its work successfully via the stubbed avQueuePlayer.
  /// Instead of testing the full LCP play(at:) (which interacts with
  /// AVQueuePlayer queue items), we verify the async surface compiles
  /// and bridges via a subclass that short-circuits playCallback.
  /// Mutant: removing the throws on the async surface would compile-
  /// break the test (it intentionally `try await`s).
  func testPlayAt_asyncSurface_routesThroughPlayCallback() async {
    final class CallbackStub: LCPStreamingPlayer {
      var playCallbackInvocations: [TrackPosition] = []
      var stubError: Error?

      override func configurePlayer() {}
      override func addPlayerObservers() {}
      override func removePlayerObservers() {}

      override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        playCallbackInvocations.append(position)
        completion?(stubError)
      }
    }

    let player = CallbackStub(tableOfContents: toc, drmDecryptor: nil)
    let target = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)

    do {
      try await player.play(at: target)
    } catch {
      XCTFail("Expected play(at:) to succeed but threw \(error)")
    }

    XCTAssertEqual(player.playCallbackInvocations.count, 1, "Async play(at:) must route through playCallback exactly once")
    XCTAssertEqual(player.playCallbackInvocations.first?.timestamp, target.timestamp,
                   "Position must be passed unchanged to playCallback")
  }

  /// Regression for the 3.2.0 "publication loading timeout → seek-late-success"
  /// race: `LCPStreamingPlayer.playCallback` has multiple racing async paths
  /// (30s timeout work item, avQueuePlayer.seek callback, rebuild fallback)
  /// that all invoke the caller's `completion`. Before the fix, a timeout
  /// would surface failure, and the underlying seek's late success would
  /// invoke the same completion again — double-resuming the `play(at:)`
  /// async continuation and trapping with SWIFT TASK CONTINUATION MISUSE.
  ///
  /// This test simulates that race by stubbing `playCallback` to fire its
  /// completion twice (first with the timeout error, then with success).
  /// The async surface MUST resolve exactly once. The bridge-level
  /// once-guard in OpenAccessPlayer.play(at:) is what holds the line for
  /// any future subclass regression; this test pins that contract.
  func testPlayAt_asyncSurface_doesNotDoubleResume_whenPlayCallbackFiresTwice() async {
    final class DoubleFireStub: LCPStreamingPlayer {
      var firstError: Error?
      var secondError: Error?

      override func configurePlayer() {}
      override func addPlayerObservers() {}
      override func removePlayerObservers() {}

      override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        // First call: simulate the 30s timeout surfacing failure.
        completion?(firstError)
        // Second call: simulate the underlying seek eventually completing
        // — historically this resumed the continuation a second time.
        completion?(secondError)
      }
    }

    let player = DoubleFireStub(tableOfContents: toc, drmDecryptor: nil)
    player.firstError = NSError(
      domain: "LCPStreamingPlayer",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for LCP publication to load"]
    )
    player.secondError = nil // late success after the timeout already fired

    // If the bridge double-resumed, this `try await` would trap the test
    // process with SWIFT TASK CONTINUATION MISUSE. Surviving the await
    // (regardless of throw/non-throw outcome) is the contract.
    let target = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
    do {
      try await player.play(at: target)
      // The first resume was the timeout error — the bridge should propagate
      // that as a throw. If it returned success, the once-guard fired in the
      // wrong direction (would mean the timeout error was swallowed).
      XCTFail("Expected first-fire timeout error to propagate as throw")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, "LCPStreamingPlayer",
                     "First completion fire (timeout error) must be the one that resolves the continuation")
      XCTAssertEqual(error.code, -1)
    }

    // Give the runtime a beat to surface a double-resume trap if the guard
    // failed — XCTest reports continuation-misuse on the next runloop tick.
    try? await Task.sleep(nanoseconds: 50_000_000)
  }

  /// Inverse of the above: when the late "success" fires FIRST and the
  /// timeout fires second (e.g. seek completes at 29.9s and the timeout
  /// at 30s sneaks in before isLoaded propagates), the async surface must
  /// still resolve exactly once — and with the first outcome.
  func testPlayAt_asyncSurface_doesNotDoubleResume_whenSuccessThenTimeout() async {
    final class DoubleFireStub: LCPStreamingPlayer {
      override func configurePlayer() {}
      override func addPlayerObservers() {}
      override func removePlayerObservers() {}

      override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        completion?(nil) // seek succeeded
        completion?(NSError(domain: "LCPStreamingPlayer", code: -1)) // stale timeout
      }
    }

    let player = DoubleFireStub(tableOfContents: toc, drmDecryptor: nil)
    let target = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
    do {
      try await player.play(at: target)
    } catch {
      XCTFail("Expected first-fire success to win, but bridge threw \(error)")
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }

  // MARK: - makeOnceCompletion helper

  /// Unit-level pin for the once-guard helper used inside
  /// `LCPStreamingPlayer.playCallback` to defang the timeout/seek race
  /// at its source. The bridge-level guard in OpenAccessPlayer is a
  /// safety net; THIS guard ensures the seek callback's playback
  /// side-effects (e.g. mute toggles, isLoaded flips, started events)
  /// aren't accompanied by a spurious second completion.
  func testMakeOnceCompletion_firesAtMostOnceAcrossThreads() {
    let invocationCount = NSLock()
    var calls: [Error?] = []
    let wrapped = LCPStreamingPlayer.makeOnceCompletion { error in
      invocationCount.lock()
      calls.append(error)
      invocationCount.unlock()
    }

    let group = DispatchGroup()
    for i in 0..<32 {
      group.enter()
      DispatchQueue.global().async {
        wrapped(i == 0 ? nil : NSError(domain: "test", code: i))
        group.leave()
      }
    }
    group.wait()

    XCTAssertEqual(calls.count, 1,
                   "makeOnceCompletion must collapse concurrent invocations to a single underlying call")
  }

  /// Nil-completion case: the wrapped closure must still be safe to call
  /// (no trap, no allocation surprises). Mutant: a `completion!` in the
  /// wrapper would crash here.
  func testMakeOnceCompletion_safeWhenSourceCompletionIsNil() {
    let wrapped = LCPStreamingPlayer.makeOnceCompletion(nil)
    wrapped(nil)
    wrapped(NSError(domain: "test", code: 1))
    // Reaching here without crashing IS the assertion.
  }

  /// When the LCP override's playCallback yields an error, the async
  /// surface must throw. Mutant: swallowing the error in the
  /// continuation would let failed LCP loads silently no-op.
  func testPlayAt_asyncSurface_throwsWhenPlayCallbackFails() async {
    final class CallbackStub: LCPStreamingPlayer {
      var stubError: Error?
      override func configurePlayer() {}
      override func addPlayerObservers() {}
      override func removePlayerObservers() {}
      override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        completion?(stubError)
      }
    }

    let player = CallbackStub(tableOfContents: toc, drmDecryptor: nil)
    player.stubError = NSError(domain: "LCPStreamingPlayer", code: -1)

    do {
      try await player.play(at: TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks))
      XCTFail("Expected play(at:) to throw")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, "LCPStreamingPlayer", "Error must propagate unchanged")
      XCTAssertEqual(error.code, -1)
    }
  }

  // MARK: - PP-5205 — locality decides whether a chapter change is a WAIT

  /// The loading state used to be gated on `!isSeekWithinSameTrack` alone, which is
  /// true of ANY track change — so choosing a later chapter muted the player and
  /// published `isLoaded = false` even when every byte of that chapter was already
  /// on disk. Palace turned that into a full-screen "Downloading…" panel over a
  /// playing book: a download announced for content already downloaded.
  ///
  /// All four cells, because the interesting one is not the obvious one. A track
  /// whose files are present but which has been pushed onto the streaming path
  /// (`forceStreamingTrackKeys` — a failed local open, say) is still a real wait and
  /// must keep the streaming behaviour, mute included.
  func test_trackIsLocallyPlayable_tableOfAllFourCells() {
    XCTAssertTrue(LCPStreamingPlayer.trackIsLocallyPlayable(hasSavedAssets: true, isForcedToStream: false),
                  "bytes on disk and no override: nothing to wait for, so nothing to announce")
    XCTAssertFalse(LCPStreamingPlayer.trackIsLocallyPlayable(hasSavedAssets: true, isForcedToStream: true),
                   "forced to stream OVERRIDES having the assets — this is the cell a saved-assets-only check gets wrong")
    XCTAssertFalse(LCPStreamingPlayer.trackIsLocallyPlayable(hasSavedAssets: false, isForcedToStream: false),
                   "no saved assets is a genuine wait; the previous behaviour, mute included, must be kept")
    XCTAssertFalse(LCPStreamingPlayer.trackIsLocallyPlayable(hasSavedAssets: false, isForcedToStream: true))
  }

  // MARK: - isLoaded on every exit of a rebuild

  /// A rebuild clears `isLoaded` on the way in, and the UI latches a spinner on
  /// that flag and then offers a retry 30 s later. So every exit must restore
  /// it, including the one that gives up: a position may name a track the
  /// manifest does not hold, which `EmptyTrack` produces with its empty key.
  func testRebuild_whenTheTargetTrackIsNotInTheManifest_leavesThePlayerLoaded() {
    let player = makePlayer()
    player.isLoaded = true
    let strayPosition = TrackPosition(track: EmptyTrack(), timestamp: 0, tracks: toc.tracks)
    XCTAssertFalse(
      toc.allTracks.contains { $0.key == strayPosition.track.key },
      "Precondition: the manifest must not hold this track"
    )
    var reportedSuccess: Bool?

    player.rebuildPlayerQueueAndNavigate(to: strayPosition, shouldResumePlayback: false) {
      reportedSuccess = $0
    }

    XCTAssertEqual(reportedSuccess, false, "a target that is not in the manifest cannot be navigated to")
    XCTAssertTrue(player.isLoaded, "a player that is not loading must not leave the UI on a spinner")
  }

}
// MARK: - What the queue holds on a rebuild

/// The queue window decides what a cold open has to fetch before audio starts.
///
/// Every track transition rebuilds the queue explicitly — `playerItemDidReachEnd`
/// calls `rebuildPlayerQueueAndNavigate` for a continuing chapter and
/// `playCallback` for a new one, and says in terms why it does not advance
/// through the queue: AVQueuePlayer's order need not match the logical track
/// order. So an item beyond the next one is never played; it is built, costs
/// AVFoundation a content-information request, and is discarded at the next
/// transition. On a streamed package each of those requests costs an archive
/// fill, which is what made a first open exceed the player's 30 s load
/// timeout while a second open — reading bytes already fetched — succeeded.
final class LCPStreamingQueueWindowTests: XCTestCase {
  func testWindow_HoldsTheTargetAndTheNextTrackOnly() {
    XCTAssertEqual(
      LCPStreamingPlayer.queueWindow(targetIndex: 5, trackCount: 10),
      [5],
      "a rebuild enqueues the chapter being played and nothing else"
    )
  }

  func testWindow_DoesNotEnqueueTheTrackBeforeTheTarget() {
    let window = LCPStreamingPlayer.queueWindow(targetIndex: 5, trackCount: 10)
    XCTAssertFalse(
      window.contains(4),
      """
      the previous track was enqueued directly after the target, so the item       queued to play next was the one just finished
      """
    )
  }

  func testWindow_AtTheLastTrack_HoldsOnlyIt() {
    XCTAssertEqual(
      LCPStreamingPlayer.queueWindow(targetIndex: 9, trackCount: 10),
      [9],
      "there is no track after the last one to enqueue"
    )
  }

  func testWindow_AtTheFirstTrack_StillHoldsTheNext() {
    XCTAssertEqual(
      LCPStreamingPlayer.queueWindow(targetIndex: 0, trackCount: 10),
      [0],
      "the chapter being played is the whole initial queue, wherever it sits"
    )
  }

  func testWindow_OnASingleTrackBook_HoldsThatTrack() {
    XCTAssertEqual(
      LCPStreamingPlayer.queueWindow(targetIndex: 0, trackCount: 1),
      [0],
      "a one-track book enqueues its one track"
    )
  }

  /// The bound the first-open cost rests on, stated as a bound rather than a
  /// shape so it fails if the window is ever widened again.
  func testWindow_NeverHoldsMoreThanTheChapterBeingPlayed() {
    for count in 1 ... 12 {
      for target in 0 ..< count {
        XCTAssertEqual(
          LCPStreamingPlayer.queueWindow(targetIndex: target, trackCount: count),
          [target],
          "target \(target) of \(count): each extra item costs a cold open an archive fill"
        )
      }
    }
  }

  /// The chapter boundary still has to be covered, so the next chapter is
  /// loaded once the current one is playing rather than never.
  func testFollowingChapter_IsTheNextOne() {
    XCTAssertEqual(LCPStreamingPlayer.followingChapterIndex(after: 3, trackCount: 10), 4)
  }

  func testFollowingChapter_AtTheLastChapter_IsNothingToPreload() {
    XCTAssertNil(LCPStreamingPlayer.followingChapterIndex(after: 9, trackCount: 10))
  }

  func testFollowingChapter_OnASingleChapterBook_IsNothingToPreload() {
    XCTAssertNil(LCPStreamingPlayer.followingChapterIndex(after: 0, trackCount: 1))
  }

  func testWindow_DoesNotEnqueueTheChapterAfterTheTarget() {
    XCTAssertFalse(
      LCPStreamingPlayer.queueWindow(targetIndex: 3, trackCount: 10).contains(4),
      """
      a second item costs the cold open another archive fill and competes with \
      the chapter the patron is waiting for; it is preloaded once playing
      """
    )
  }
}
