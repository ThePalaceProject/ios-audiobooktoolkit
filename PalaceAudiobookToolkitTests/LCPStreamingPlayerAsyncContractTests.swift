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
import Combine
import ReadiumShared
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
    let wrapped = LCPStreamingPlayer.makeOnceCompletion { (error: Error?) in
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
    let wrapped = LCPStreamingPlayer.makeOnceCompletion(nil as ((Error?) -> Void)?)
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

  /// `publicationDidLoad` must not consult `isLoaded`. An empty queue returns
  /// the player to not-loaded, and the queue is built lazily on the next
  /// `playCallback`.
  ///
  /// The rebuild's give-up exit empties the queue and then reports the player
  /// loaded, which is right for the spinner. Reading `isLoaded` here as well
  /// therefore left a player resting at loaded with nothing queued.
  func testPublicationDidLoad_withAnEmptyQueue_returnsThePlayerToNotLoaded() {
    let player = makePlayer()
    player.isLoaded = true
    XCTAssertTrue(player.avQueuePlayer.items().isEmpty, "Precondition: nothing is queued")

    player.publicationDidLoad()

    XCTAssertFalse(
      player.isLoaded,
      "an empty queue is not a loaded player, whatever the flag said on the way in"
    )
  }

  /// The converse, so the queue rebuild cannot be made unconditional: a queue
  /// that holds items is already playable and resetting it would discard them.
  func testPublicationDidLoad_withAQueuedItem_leavesTheQueueAndTheFlagAlone() {
    let player = makePlayer()
    player.isLoaded = true
    let queued = AVPlayerItem(url: Self.silentItemURL)
    player.avQueuePlayer.insert(queued, after: nil)

    player.publicationDidLoad()

    XCTAssertEqual(player.avQueuePlayer.items(), [queued], "a playable queue must be left alone")
    XCTAssertTrue(player.isLoaded, "a player with something to play stays loaded")
  }

  // MARK: - The preload is the only thing covering a chapter boundary

  /// Since a rebuild enqueues one chapter, the following chapter is warmed by
  /// the preload alone. Nothing else holds that property, so it is asserted on
  /// the queue rather than on the index arithmetic.
  func testPreloadFollowingChapter_warmsTheNextChapter() throws {
    let player = makePlayer()
    let tracks = toc.allTracks
    try XCTSkipUnless(tracks.count >= 2, "Fixture must have a following chapter")
    let current = AVPlayerItem(url: Self.silentItemURL)
    current.trackIdentifier = tracks[0].key
    player.avQueuePlayer.insert(current, after: nil)

    player.preloadFollowingChapter()

    XCTAssertEqual(
      player.avQueuePlayer.items().compactMap(\.trackIdentifier),
      [tracks[0].key, tracks[1].key],
      "the following chapter must be queued behind the one playing, in that order"
    )
  }

  /// The preload is armed once per chapter start but survives rebuilds and
  /// rapid skips, so a second call must not stack a duplicate.
  func testPreloadFollowingChapter_calledTwice_queuesOneCopy() throws {
    let player = makePlayer()
    let tracks = toc.allTracks
    try XCTSkipUnless(tracks.count >= 2, "Fixture must have a following chapter")
    let current = AVPlayerItem(url: Self.silentItemURL)
    current.trackIdentifier = tracks[0].key
    player.avQueuePlayer.insert(current, after: nil)

    player.preloadFollowingChapter()
    player.preloadFollowingChapter()

    XCTAssertEqual(
      player.avQueuePlayer.items().filter { $0.trackIdentifier == tracks[1].key }.count,
      1,
      "a repeated preload must not stack another copy of the same chapter"
    )
  }

  /// The last chapter has no successor, so the preload must not queue anything.
  func testPreloadFollowingChapter_onTheLastChapter_queuesNothing() throws {
    let player = makePlayer()
    let tracks = toc.allTracks
    let last = try XCTUnwrap(tracks.last)
    let current = AVPlayerItem(url: Self.silentItemURL)
    current.trackIdentifier = last.key
    player.avQueuePlayer.insert(current, after: nil)

    player.preloadFollowingChapter()

    XCTAssertEqual(
      player.avQueuePlayer.items().count,
      1,
      "there is no chapter after the last one to warm"
    )
  }

  private static let silentItemURL: URL = SilentAudioFixture.url

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
    player.isLoaded = false
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

  /// A track that ends before the preload fires empties the queue, so the
  /// chapter boundary falls to a full rebuild and the patron hears a gap where
  /// a seam belongs. Short tracks are real in audiobooks: an "end of part"
  /// track runs a few seconds.
  func testPreloadDelay_OnATrackShorterThanTheDelay_FiresBeforeItEnds() {
    let delay = LCPStreamingPlayer.preloadDelay(forTimeRemaining: 4)
    XCTAssertLessThan(delay, 4, "the preload must fire while the track is still playing")
    XCTAssertEqual(delay, 2)
  }

  /// Keyed on what is left to play, not the track's length. A chapter resumed
  /// near its end has only seconds of audio in front of the boundary, so the
  /// full settle would expire after the queue had already run dry.
  func testPreloadDelay_OnAChapterResumedNearItsEnd_FiresBeforeItEnds() {
    let delay = LCPStreamingPlayer.preloadDelay(forTimeRemaining: 2)
    XCTAssertLessThan(delay, 2, "a resumed chapter must still warm the next one")
    XCTAssertEqual(delay, 1)
  }

  func testPreloadDelay_WithAFullChapterLeft_LetsTheChapterSettle() {
    XCTAssertEqual(
      LCPStreamingPlayer.preloadDelay(forTimeRemaining: 1800),
      LCPStreamingPlayer.defaultPreloadDelay,
      "a normal chapter keeps the full settle time, so the preload cannot stall its audio"
    )
  }

  /// A manifest need not carry a duration, and halving an unknown would preload
  /// at once and compete with the chapter the patron is waiting for.
  /// A manifest need not carry a duration, which makes the remainder zero or
  /// negative. Halving that would preload at once and compete with the chapter
  /// the patron is waiting for.
  func testPreloadDelay_WithNoKnownRemainder_KeepsTheDefault() {
    XCTAssertEqual(
      LCPStreamingPlayer.preloadDelay(forTimeRemaining: 0),
      LCPStreamingPlayer.defaultPreloadDelay
    )
    XCTAssertEqual(
      LCPStreamingPlayer.preloadDelay(forTimeRemaining: -30),
      LCPStreamingPlayer.defaultPreloadDelay,
      "a timestamp past a stale duration must not collapse the delay"
    )
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

// MARK: - Streaming load lifecycle and the progress-aware load timeout (PP-5367)

/// Records the provider hooks the player uses to hand the link to a chapter the
/// patron is waiting for.
///
/// Held strongly by each test: `LCPStreamingPlayer.streamingProvider` is weak.
private final class SpyStreamingProvider: StreamingResourceProvider {
  var events: [String] = []
  var begins: Int { events.filter { $0 == "begin" }.count }
  var ends: Int { events.filter { $0 == "end" }.count }

  func getPublication() -> Publication? { nil }
  func archiveIsLocalFile() -> Bool { false }
  func streamingLoadDidBegin() { events.append("begin") }
  func streamingLoadDidEnd() { events.append("end") }
}

@MainActor
final class LCPStreamingLoadLifecycleTests: XCTestCase {

  /// Shortens the shipped windows and stands in for the resource loader's byte
  /// counter, so the real timer and the real failure path run in milliseconds.
  final class LifecyclePlayer: LCPStreamingPlayer {
    var window: TimeInterval = 0.05
    var ceiling: TimeInterval = 10
    /// Bytes "arriving" between two samples. Zero models a load that is
    /// receiving nothing at all.
    var bytesPerSample = 0
    private var served = 0

    override var loadProgressWindow: TimeInterval { window }
    override var loadCeiling: TimeInterval { ceiling }
    override var streamedBytesServed: Int {
      served += bytesPerSample
      return served
    }

    override func configurePlayer() {}
    override func addPlayerObservers() {}
    override func removePlayerObservers() {}
  }

  private var toc: AudiobookTableOfContents!
  private var firstTrack: (any Track)!
  private var provider: SpyStreamingProvider!

  override func setUp() async throws {
    try await super.setUp()
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "lcp-yield-test", decryptor: nil, token: nil)
    )
    toc = audiobook.tableOfContents
    firstTrack = try XCTUnwrap(toc.allTracks.first)
    provider = SpyStreamingProvider()
  }

  private func makePlayer() -> LifecyclePlayer {
    let player = LifecyclePlayer(tableOfContents: toc, drmDecryptor: nil)
    player.setStreamingProvider(provider)
    return player
  }

  private var position: TrackPosition {
    TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
  }

  /// Begins a load the way `playCallback` does, through the shipped timer.
  private func beginLoad(on player: LifecyclePlayer, completion: @escaping (Error?) -> Void = { _ in }) {
    player.isLoaded = false
    player.beginStreamingLoad()
    player.armLoadTimeout(
      for: position,
      startedAt: Date(),
      bytesAtLastCheck: player.streamedBytesServed,
      onceCompletion: completion
    )
  }

  // MARK: - Balance across every exit

  /// The timeout is an exit: it must release the provider it asked to yield,
  /// or the patron's background download stays suspended with nothing left to
  /// resume it.
  func testStreamingLoad_whenTheTimeoutFires_endsTheLoadItBegan() async throws {
    let player = makePlayer()
    beginLoad(on: player)
    XCTAssertEqual(provider.events, ["begin"], "Arming the load must announce it")

    try await Task.sleep(nanoseconds: 300_000_000)

    XCTAssertEqual(provider.events, ["begin", "end"],
                   "A load the timeout failed must be announced as ended exactly once")
  }

  /// Teardown does not flip `isLoaded`, so it is one of the two paths that
  /// release the provider explicitly.
  func testStreamingLoad_onUnload_endsTheLoadItBegan() {
    let player = makePlayer()
    beginLoad(on: player)

    player.unload()

    XCTAssertEqual(provider.events, ["begin", "end"],
                   "Teardown must release a load that was still open")
  }

  /// The other six exits all reach the load's end by flipping `isLoaded` —
  /// the seek completion, the rebuild's seek completion, the local
  /// cross-track seek, `timeControlStatus == .playing`, and both of
  /// `rebuildPlayerQueueAndNavigate`'s nothing-to-wait-on arms.
  func testStreamingLoad_whenTheLoadedFlagFlips_endsTheLoadItBegan() {
    let player = makePlayer()
    beginLoad(on: player)

    player.isLoaded = true

    XCTAssertEqual(provider.events, ["begin", "end"],
                   "Reaching loaded must release the provider")
  }

  /// Driven through the real `rebuildPlayerQueueAndNavigate`, so the balance is
  /// asserted over shipped control flow rather than over the flag alone. The
  /// give-up arm — a position naming a track the manifest does not hold — is
  /// the one that would otherwise leave a load open with no seek to end it.
  func testStreamingLoad_whenARebuildFindsNoTargetTrack_endsTheLoadItBegan() {
    let player = makePlayer()
    beginLoad(on: player)
    let strayPosition = TrackPosition(track: EmptyTrack(), timestamp: 0, tracks: toc.tracks)
    XCTAssertFalse(
      toc.allTracks.contains { $0.key == strayPosition.track.key },
      "Precondition: the manifest must not hold this track"
    )

    player.rebuildPlayerQueueAndNavigate(to: strayPosition, shouldResumePlayback: false) { _ in }

    XCTAssertEqual(provider.events, ["begin", "end"],
                   "A rebuild that cannot navigate must release the provider")
  }

  /// A second announcement for one load would have the app suspend a download
  /// twice and need two resumes to undo it.
  func testStreamingLoad_begunTwice_isAnnouncedOnce() {
    let player = makePlayer()
    beginLoad(on: player)
    player.beginStreamingLoad()

    XCTAssertEqual(provider.events, ["begin"], "One load, one announcement")

    player.isLoaded = true
    XCTAssertEqual(provider.events, ["begin", "end"], "And one release")
  }

  /// A late exit after the timeout already ended the load must not release the
  /// provider a second time — that would resume a download a LATER load is
  /// waiting on.
  func testStreamingLoad_endedTwice_releasesOnce() async throws {
    let player = makePlayer()
    beginLoad(on: player)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(provider.events, ["begin", "end"], "Precondition: the timeout ended it")

    player.isLoaded = true
    player.unload()

    XCTAssertEqual(provider.events, ["begin", "end"], "Later exits must be no-ops")
  }

  /// Two loads in a row — the owner's case is skipping chapter after chapter —
  /// must each be announced and each released.
  func testStreamingLoad_perSeek_isAnnouncedAndReleasedEachTime() {
    let player = makePlayer()
    beginLoad(on: player)
    player.isLoaded = true
    beginLoad(on: player)
    player.isLoaded = true

    XCTAssertEqual(provider.events, ["begin", "end", "begin", "end"],
                   "The hooks are per load event, not once per player")
  }

  // MARK: - Progress-aware timeout

  func test_loadTimeoutOutcome_bytesArrivingInsideTheCeiling_rearms() {
    XCTAssertEqual(
      LCPStreamingPlayer.loadTimeoutOutcome(bytesServed: 2048, bytesAtLastCheck: 1024, elapsed: 30, ceiling: 90),
      .rearm
    )
  }

  func test_loadTimeoutOutcome_noBytesInsideTheCeiling_fails() {
    XCTAssertEqual(
      LCPStreamingPlayer.loadTimeoutOutcome(bytesServed: 1024, bytesAtLastCheck: 1024, elapsed: 30, ceiling: 90),
      .fail
    )
  }

  func test_loadTimeoutOutcome_bytesArrivingPastTheCeiling_fails() {
    XCTAssertEqual(
      LCPStreamingPlayer.loadTimeoutOutcome(bytesServed: 2048, bytesAtLastCheck: 1024, elapsed: 90, ceiling: 90),
      .fail
    )
  }

  func test_loadTimeoutOutcome_noBytesPastTheCeiling_fails() {
    XCTAssertEqual(
      LCPStreamingPlayer.loadTimeoutOutcome(bytesServed: 1024, bytesAtLastCheck: 1024, elapsed: 120, ceiling: 90),
      .fail
    )
  }

  /// The defect the owner reported: a cross-chapter seek that is slow because
  /// the background package fetch is competing for the link gets killed at the
  /// window and the patron loses the book. While bytes keep arriving the load
  /// must be left alone.
  func testLoadTimeout_whileBytesKeepArriving_doesNotFailTheLoad() async throws {
    let player = makePlayer()
    player.bytesPerSample = 128 * 1024
    player.ceiling = 60
    var failure: Error?
    beginLoad(on: player) { failure = $0 }

    // Eight progress windows' worth of a load that is making headway.
    try await Task.sleep(nanoseconds: 400_000_000)

    XCTAssertNil(failure, "A load still receiving bytes must not be failed at the window")
    XCTAssertFalse(player.isLoaded, "Precondition: nothing else completed the load")
    XCTAssertEqual(provider.events, ["begin"], "And the load is still open, so the provider stays yielded")
  }

  /// The timeout still has to catch a load that is receiving nothing, as
  /// promptly as it does today.
  func testLoadTimeout_withNoBytesArriving_failsAtTheWindow() async throws {
    let player = makePlayer()
    player.bytesPerSample = 0
    var failure: NSError?
    beginLoad(on: player) { failure = $0 as NSError? }

    try await Task.sleep(nanoseconds: 300_000_000)

    XCTAssertEqual(failure?.domain, "LCPStreamingPlayer")
    XCTAssertEqual(
      failure?.localizedDescription,
      "Timed out waiting for LCP publication to load",
      "A load with no bytes must still surface the failure the app shows an alert for"
    )
  }

  /// The ceiling: a load that keeps dribbling bytes for ever still ends, so a
  /// stalled-but-not-silent transfer cannot hang the player.
  func testLoadTimeout_whenBytesArrivePastTheCeiling_failsAnyway() async throws {
    let player = makePlayer()
    player.bytesPerSample = 1024
    player.ceiling = 0.15
    var failure: NSError?
    beginLoad(on: player) { failure = $0 as NSError? }

    try await Task.sleep(nanoseconds: 600_000_000)

    XCTAssertEqual(
      failure?.localizedDescription,
      "Timed out waiting for LCP publication to load",
      "Progress may extend the wait, not remove its bound"
    )
    XCTAssertEqual(provider.events, ["begin", "end"], "And the provider is released on that exit too")
  }

  /// The failure must keep reaching the app, which is what drives the
  /// "Audiobook Unavailable" alert and releases the open lock.
  func testLoadTimeout_whenItFails_publishesAPlaybackFailure() async throws {
    let player = makePlayer()
    player.bytesPerSample = 0
    var states: [PlaybackState] = []
    let cancellable = player.playbackStatePublisher.sink { states.append($0) }
    defer { cancellable.cancel() }

    beginLoad(on: player) { _ in }
    try await Task.sleep(nanoseconds: 300_000_000)

    let failed = states.contains { state in
      if case .failed = state { return true }
      return false
    }
    XCTAssertTrue(failed, "The timeout must publish .failed so the host can alert")
  }
}
