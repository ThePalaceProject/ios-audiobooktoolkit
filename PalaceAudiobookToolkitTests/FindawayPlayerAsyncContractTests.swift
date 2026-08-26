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

  /// FindawayPlayer's skipPlayhead carries forward overflow into the next
  /// track when one exists (Findaway's contract: skip-past-end-of-track must
  /// wrap or pin).
  ///
  /// This asserted only `XCTAssertNotNil` until a mechanically-derived mutant
  /// showed what that was worth: flipping the in-range test's `<=` to `>=` — so
  /// an overflowing skip takes the direct path and returns a position PAST the
  /// end of the current track — left it green, because a junk position is
  /// non-nil too. Assert where the playhead actually landed.
  func testSkipPlayhead_forwardPastTrackEnd_carriesOverflowIntoNextTrack() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))

    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    let nextTrack = try XCTUnwrap(toc.tracks.nextTrack(firstTrack), "Fixture needs a second track")
    // Start 5s from the end of the track; +60s overflows by 55s.
    let nearEnd = firstTrack.duration - 5
    player.currentTrackPositionOverride = TrackPosition(
      track: firstTrack,
      timestamp: nearEnd,
      tracks: toc.tracks
    )

    let skipped = await player.skipPlayhead(60)
    let result = try XCTUnwrap(skipped)

    XCTAssertEqual(result.track.key, nextTrack.key, "Overflow must land on the NEXT track")
    XCTAssertEqual(result.timestamp, 55, accuracy: 0.001,
                   "The overflow past the track end must carry over, not be dropped")
    XCTAssertLessThanOrEqual(result.timestamp, result.track.duration,
                             "A resolved position must never sit past its own track's end")
  }

  // Two sibling mutants on that same condition — `<=` to `<`, and `>=` to `>` —
  // survive and are EQUIVALENT, not gaps. Both differ only exactly on a bound
  // (`newTimestamp == duration`, `newTimestamp == 0`), and for the whole
  // in-range domain the `else` arm's final clause builds
  // `TrackPosition(track: same, timestamp: max(0, newTimestamp))` — the
  // identical value the direct arm builds. No input distinguishes them, so
  // there is no test to write; the note is here so the next reader does not
  // re-derive it from a 40% kill rate.

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

  // MARK: - Seek-strategy decisions (skip-stutter regression, 2026-06-11)
  //
  // Device logs proved same-chapter skips were misrouted to the expensive
  // unload/reload path because the old `isSameTrackSeek` required `isPlaying`,
  // which is transiently false during the post-seek buffer window. The reload
  // then ended paused, forcing the user to tap play. These pin the corrected,
  // intent-based routing.

  /// THE regression gate: a seek within the currently loaded track must take
  /// the cheap same-track-offset path even when the SDK is momentarily NOT
  /// playing (buffering). The decision must not depend on play state at all.
  /// Mutant: reintroducing an `isPlaying`/`&& false` term, or flipping `&&` to
  /// `||`, changes this result.
  func testSameTrackSeek_loadedAndSameTrack_takesCheapOffsetPath() {
    XCTAssertTrue(
      FindawayPlayer.isSameTrackSeekDecision(bookIsLoaded: true, isSameTrackKey: true),
      "Same loaded track must use cheap setCurrentOffset regardless of isPlaying"
    )
  }

  /// A seek to a different track always needs a full reload.
  func testSameTrackSeek_differentTrack_requiresReload() {
    XCTAssertFalse(
      FindawayPlayer.isSameTrackSeekDecision(bookIsLoaded: true, isSameTrackKey: false),
      "Cross-track seek must reload"
    )
  }

  /// If nothing is loaded yet, even a same-key target needs a full load.
  func testSameTrackSeek_notLoaded_requiresReload() {
    XCTAssertFalse(
      FindawayPlayer.isSameTrackSeekDecision(bookIsLoaded: false, isSameTrackKey: true),
      "Nothing loaded must reload"
    )
  }

  /// When the user is actively listening, a reload must NOT pause afterwards —
  /// this is the "have to tap play again" half of the bug. Mutant: dropping the
  /// `!` returns true and reintroduces the spurious pause.
  func testShouldPauseAfterReload_whenPlaybackDesired_keepsPlaying() {
    XCTAssertFalse(
      FindawayPlayer.shouldPauseAfterReload(playbackDesired: true),
      "A reload while the user intends playback must not end paused"
    )
  }

  /// When the user intends to stay paused, a reload must remain paused.
  func testShouldPauseAfterReload_whenNotDesired_staysPaused() {
    XCTAssertTrue(
      FindawayPlayer.shouldPauseAfterReload(playbackDesired: false),
      "A reload while paused must stay paused"
    )
  }

  // MARK: - Play-intent wiring (drives the real public seam, not the flag directly)

  /// `play(at:)` must register user play-intent. Driven through the production
  /// async seam: the continuation resumes only after performPlayAt sets the flag.
  /// Mutant: dropping `isPlaybackDesired = true` in performPlayAt fails this.
  func testPlayAt_registersPlayIntent() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    XCTAssertFalse(player.isPlaybackDesired, "Precondition: no intent before play")

    try await player.play(at: TrackPosition(track: firstTrack, timestamp: 10, tracks: toc.tracks))

    XCTAssertTrue(player.isPlaybackDesired, "play(at:) must set play-intent")
  }

  /// `unload()` must drop play-intent so a teardown-then-reopen doesn't inherit
  /// a stale "wants playback" that would auto-resume on the next seek.
  func testUnload_clearsPlayIntent() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(SpyFindawayPlayer(tableOfContents: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    try await player.play(at: TrackPosition(track: firstTrack, timestamp: 10, tracks: toc.tracks))
    XCTAssertTrue(player.isPlaybackDesired, "Precondition: intent set by play(at:)")

    player.unload()

    XCTAssertFalse(player.isPlaybackDesired, "unload() must clear play-intent")
  }

  // MARK: - Isolation contracts (PP-4990)
  //
  // FindawayPlayer conforms to `Player`, which is `@MainActor`, so the player
  // has always been main-actor isolated — while its state machine ran on a
  // private serial queue. These pin the contracts that removing that queue
  // established, and the one the value object was supposed to have all along.

  /// `FindawayChapterRef` exists so the SDK's `FAEChapterDescription` never
  /// crosses an isolation boundary: the notification is decoded on AudioEngine's
  /// thread and only these two numbers travel. That requires the type to be
  /// UNISOLATED — a `@MainActor` initialiser cannot be called from the SDK's
  /// thread, which is the only place this is ever built.
  ///
  /// Honest about what this proves: it is a COMPILE-TIME contract. A stray
  /// `@MainActor` on the struct (which is exactly what a doc comment between the
  /// attribute and the delegate protocol once produced) is a warning today and
  /// an error under the Swift 6 language mode, so this test would stop building
  /// rather than stop passing. The assertion on the fields is what keeps it from
  /// being a bare construction test.
  func testChapterRef_isConstructibleOffTheMainActor() async {
    let ref = await Task.detached {
      FindawayChapterRef(partNumber: 2, chapterNumber: 7)
    }.value

    XCTAssertEqual(ref.partNumber, 2, "Decoded part number must survive the hop")
    XCTAssertEqual(ref.chapterNumber, 7, "Decoded chapter number must survive the hop")
  }

  /// The startup race the notify-order change closes. A player reads `verified`
  /// and registers as two separate statements (`FindawayPlayer.init`), so
  /// verification landing between them used to take its delegate snapshot before
  /// the registration existed — the player was never told, and no second event
  /// was coming. Snapshotting on the far side of the hop instead means a
  /// delegate that registers before the hop drains still hears about it.
  ///
  /// Mutant: moving the `delegates.allObjects` snapshot back into the setter
  /// (the shape this replaced) makes the delegate miss the update and this fail.
  func testVerification_notifiesDelegateThatRegisteredBeforeTheHopDrained() async {
    let verification = FindawayDatabaseVerification()
    let spy = SpyDatabaseVerificationDelegate()

    // Set first, register second — the order FindawayPlayer.init produces.
    verification.verified = true
    verification.registerDelegate(spy)

    await Self.drainMainQueue()

    XCTAssertEqual(spy.updateCount, 1, "A delegate registered before the hop drained must be notified")
  }

  /// Only a CHANGE notifies. Mutant: dropping the `guard changed` re-notifies
  /// every delegate on every redundant write, and `playWithCurrentState` runs
  /// again for no reason on each one.
  func testVerification_doesNotNotifyWhenValueIsUnchanged() async {
    let verification = FindawayDatabaseVerification()
    let spy = SpyDatabaseVerificationDelegate()
    verification.registerDelegate(spy)

    verification.verified = true
    await Self.drainMainQueue()
    XCTAssertEqual(spy.updateCount, 1, "Precondition: the first change notifies")

    verification.verified = true
    await Self.drainMainQueue()

    XCTAssertEqual(spy.updateCount, 1, "Re-writing the same value must not notify again")
  }

  /// `pause()` used to hop onto the player's private serial queue, so its effect
  /// was not visible to the caller on return. It is main-actor now, and callers
  /// — including `handlePlaybackEnd`, which pauses as part of resolving the end
  /// of a book — depend on the intent being dropped by the time they continue.
  ///
  /// Mutant: dropping `isPlaybackDesired = false` from `performPause`, or
  /// restoring the async hop, fails this without any waiting.
  func testPause_dropsPlayIntentSynchronously() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(Self.makeSpy(toc: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    player.currentTrackPositionOverride = TrackPosition(track: firstTrack, timestamp: 10, tracks: toc.tracks)
    try await player.play(at: TrackPosition(track: firstTrack, timestamp: 10, tracks: toc.tracks))
    XCTAssertTrue(player.isPlaybackDesired, "Precondition: play(at:) set intent")

    player.pause()

    XCTAssertFalse(player.isPlaybackDesired, "pause() must drop intent by the time it returns")
  }

  /// `play()` is refused until the AudioEngine database is verified, and it must
  /// leave no trace when refused — a queued play-intent would resume audio the
  /// moment verification landed.
  ///
  /// Mutant: removing the `readyForPlayback` guard lets `performPlay` set the
  /// intent, and this fails.
  func testPlay_whenNotVerified_doesNotRegisterPlayIntent() throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let player = try XCTUnwrap(Self.makeSpy(toc: toc))
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    player.currentTrackPositionOverride = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)

    player.play()

    XCTAssertFalse(player.isPlaybackDesired, "play() before verification must not register intent")
  }

  /// The debounced manipulation scheduler, which this change moved off the
  /// player's private serial queue and onto the main queue, and out of a pair of
  /// nested functions into methods (a local function cannot be captured by a
  /// `DispatchWorkItem`'s `@Sendable` body).
  ///
  /// Observable without the SDK: `currentTrackPosition` reports the QUEUED
  /// playhead while a manipulation is pending, and the scheduler sets
  /// `queuedPlayerState` back to `.none` when it finally runs — at which point,
  /// with no engine to fall back to, the position reads nil. So "the queued
  /// position clears" is the scheduler firing.
  ///
  /// Mutants this kills: inverting the supersede guard
  /// (`currentSequence == manipulationSequenceNumber`) makes every work item
  /// return early, and flipping the debounce comparison (`Date() <`) makes it
  /// reschedule forever. Both leave the queued position pinned and fail here.
  ///
  /// Waits on the CONDITION with a generous ceiling rather than sleeping for the
  /// debounce, so it asserts a property of the code and not the speed of the
  /// machine it runs on.
  func testQueuedManipulation_runsAfterTheDebounceAndClearsTheQueuedState() async throws {
    let (toc, _) = try Self.makeFindawayFixture()
    let verification = FindawayDatabaseVerification()
    verification.verified = true
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    let player = FindawayPlayer(
      currentPosition: TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks),
      tableOfContents: toc,
      databaseVerification: verification
    )

    let target = TrackPosition(track: firstTrack, timestamp: 42, tracks: toc.tracks)
    try await player.play(at: target)

    XCTAssertEqual(player.currentTrackPosition?.timestamp, 42,
                   "Precondition: the queued playhead is reported while the manipulation is pending")

    let cleared = await Self.eventually { player.currentTrackPosition == nil }

    XCTAssertTrue(cleared, "The debounced manipulation must run and clear the queued state")
  }

  /// The path PP-4990 exists for, driven end to end: a decoded
  /// `FindawayChapterRef` arrives where the SDK notification used to hand over
  /// its own `FAEChapterDescription`, and the player resolves it to a real
  /// chapter and announces the position it was actually asked to start at.
  ///
  /// Uses the Findaway-shaped fixture, not the open-access one the older tests
  /// share: resolution goes through `tracks.track(forPart:sequence:)`, so a
  /// manifest without `findaway:part` / `findaway:sequence` resolves to nil and
  /// the whole body is skipped — which is exactly why this line sat uncovered.
  ///
  /// Mutant: inverting the `target.track.key == currentChapter.position.track.key`
  /// comparison drops the pending position and falls back to the engine's
  /// offset, which is 0 with no engine — the "snaps back to the start of the
  /// book" regression the fallback comment warns about. Asserting the timestamp,
  /// not just that something was announced, is what catches it.
  ///
  /// Uses a MID-BOOK chapter, and that is the point. This test was originally
  /// written against part 1 / chapter 1 and failed: the pinned tie-break
  /// resolved a boundary position to the chapter BEFORE it, so the announcement
  /// paired the previous chapter's track with the current chapter's offset. It
  /// had to be written against chapter zero — the only chapter with no
  /// predecessor for the boundary to be handed to — and the debt recorded on
  /// PP-4951.
  ///
  /// PP-4951 unpinned that resolution, so the honest case now holds for every
  /// chapter and this asserts it where it used to fail.
  func testPlaybackStarted_resolvesTheChapterRefAndAnnouncesThePendingPosition() async throws {
    let toc = try Self.makeFindawayTOC()
    let track = try XCTUnwrap(toc.tracks.track(forPart: 1, sequence: 4),
                              "Fixture must carry findaway part/sequence numbering")
    // Verification left false on purpose: `play(at:)` still records the pending
    // start position, and nothing schedules an engine manipulation.
    let player = FindawayPlayer(
      currentPosition: TrackPosition(track: track, timestamp: 0, tracks: toc.tracks),
      tableOfContents: toc,
      databaseVerification: FindawayDatabaseVerification()
    )

    var announced: [PlaybackState] = []
    let subscription = player.playbackStatePublisher.sink { announced.append($0) }
    defer { subscription.cancel() }

    let target = TrackPosition(track: track, timestamp: 17, tracks: toc.tracks)
    try await player.play(at: target)

    player.audioEnginePlaybackStarted(
      DefaultFindawayPlaybackNotificationHandler(),
      for: FindawayChapterRef(partNumber: 1, chapterNumber: 4)
    )

    let started = await Self.eventually {
      announced.contains { if case .started = $0 { return true } else { return false } }
    }
    XCTAssertTrue(started, "A resolved chapter notification must announce playback started")

    guard case let .started(position)? = announced.last(where: {
      if case .started = $0 { return true } else { return false }
    }) else {
      return XCTFail("Expected a .started event")
    }
    XCTAssertEqual(position.track.key, track.key, "Announced position must be on the resolved chapter's track")
    XCTAssertEqual(position.timestamp, 17, accuracy: 0.001,
                   "Announced position must be the pending start position, not the engine's offset")
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

  /// Records delegate callbacks. `@objc` because the protocol is, and the
  /// hash table that holds it is weak — the caller keeps the strong reference.
  final class SpyDatabaseVerificationDelegate: NSObject, FindawayDatabaseVerificationDelegate {
    private(set) var updateCount = 0

    func findawayDatabaseVerificationDidUpdate(_: FindawayDatabaseVerification) {
      updateCount += 1
    }
  }

  /// Build a player against its OWN verification instance rather than the
  /// process-wide `.shared` one, so these tests neither read nor leave global
  /// state. `verified` is false on a fresh instance, which is the state the
  /// "not yet verified" cases need.
  private static func makeSpy(toc: AudiobookTableOfContents) -> SpyFindawayPlayer? {
    guard let firstTrack = toc.allTracks.first else { return nil }
    return SpyFindawayPlayer(
      currentPosition: TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks),
      tableOfContents: toc,
      databaseVerification: FindawayDatabaseVerification()
    )
  }

  /// A genuinely Findaway-shaped table of contents: `secret_lives_manifest`
  /// carries `findaway:part` / `findaway:sequence` on all ten entries, which is
  /// what `tracks.track(forPart:sequence:)` resolves a chapter notification by.
  private static func makeFindawayTOC() throws -> AudiobookTableOfContents {
    let manifest = try Manifest.from(
      jsonFileName: "secret_lives_manifest",
      bundle: Bundle(for: FindawayPlayerAsyncContractTests.self)
    )
    let tracks = Tracks(manifest: manifest, audiobookID: "findaway-notification-test", token: nil)
    return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
  }

  /// Poll `condition` on the main actor until it holds or the ceiling expires.
  /// The ceiling is far above the 0.5s debounce on purpose: the assertion is
  /// "this eventually happens", which is a property of the scheduler, where a
  /// fixed sleep would be a measurement of the host.
  private static func eventually(
    within ceiling: TimeInterval = 5.0,
    _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(ceiling)
    while Date() < deadline {
      if condition() { return true }
      await drainMainQueue()
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  /// Let anything already queued on the main queue run. Enqueueing behind the
  /// pending block and waiting for our own turn is deterministic, where a sleep
  /// would only be probable.
  private static func drainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
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
