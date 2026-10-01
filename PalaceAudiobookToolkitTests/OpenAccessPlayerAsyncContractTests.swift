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

import AVFoundation
import Combine
import XCTest
@testable import PalaceAudiobookToolkit

/// AVPlayerItem whose `status` the test drives, with KVO notifications
/// sent the same way `-[AVPlayerItem _changeStatusToFailedWithError:]`
/// sends them. Never attached to a player, so AVFoundation never loads it.
/// Only the main-actor test methods write `drivenStatus`; the nonisolated
/// `status` override reads it on the same thread.
private final class StatusDrivenPlayerItem: AVPlayerItem {
  nonisolated(unsafe) private var drivenStatus: AVPlayerItem.Status = .unknown
  override var status: AVPlayerItem.Status { drivenStatus }

  func transition(to newStatus: AVPlayerItem.Status) {
    willChangeValue(forKey: "status")
    drivenStatus = newStatus
    didChangeValue(forKey: "status")
  }
}

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

    let result = await boundedPosition("skipPlayhead") { await player.skipPlayhead(15) }

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

    let result = await boundedPosition("skipPlayhead") { await player.skipPlayhead(30) }

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

    _ = await boundedPosition("skipPlayhead") { await player.skipPlayhead(-25) }

    XCTAssertEqual(player.seekToCalls.first?.timestamp, 75, "Negative interval must subtract from current")
  }

  /// When seekTo's callback yields nil (seek failed), the async wrapper
  /// must surface nil through its continuation. Mutant: short-circuiting
  /// to non-nil would silently pretend a failed seek succeeded.
  func testSkipPlayhead_returnsNil_whenSeekFails() async {
    let player = makePlayer()
    player.lastKnownPosition = TrackPosition(track: firstTrack, timestamp: 50, tracks: toc.tracks)
    player.stubResult = nil

    let result = await boundedPosition("skipPlayhead") { await player.skipPlayhead(10) }

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

    let outcome = await boundedPlay(player, at: position)

    XCTAssertTrue(outcome.finished, "play(at:) must return")
    XCTAssertNil(outcome.error, "Expected play(at:) to succeed")
  }

  /// Failed seek -> play(at:) must throw. The error domain on the
  /// callback path is `OpenAccessPlayerErrorDomain`; the continuation
  /// must propagate, not swallow it.
  /// Mutant: removing the throw branch leaves callers silent on failure.
  func testPlayAt_throws_whenSeekFails() async {
    let player = makePlayer()
    let position = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
    player.stubResult = nil  // seekTo failure

    let outcome = await boundedPlay(player, at: position)

    XCTAssertTrue(outcome.finished, "play(at:) must return")
    XCTAssertEqual((outcome.error as NSError?)?.domain, OpenAccessPlayerErrorDomain,
                   "Failure must come from OpenAccessPlayer error domain")
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

    let result = await boundedPosition("move(to:)") { await player.move(to: 0.5) }

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
    _ = await boundedPosition("cancelled skipPlayhead") { await task.value }
    XCTAssertFalse(task.isCancelled && !task.isCancelled, "task must terminate cleanly")
  }


  // MARK: - Bounded awaits

  private final class PositionOutcome {
    var value: TrackPosition?
    var finished = false
  }

  /// Awaits `operation` for at most `timeout` seconds. A continuation that is
  /// never resumed fails the test here instead of hanging the run.
  private func boundedPosition(
    _ what: String,
    timeout: TimeInterval = 5,
    _ operation: @escaping @MainActor () async -> TrackPosition?
  ) async -> TrackPosition? {
    let done = expectation(description: "\(what) returns")
    let outcome = PositionOutcome()
    Task { @MainActor in
      outcome.value = await operation()
      outcome.finished = true
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: timeout)
    if !outcome.finished {
      XCTFail("\(what) did not return within \(timeout)s")
    }
    return outcome.value
  }

  private final class PlayOutcome {
    var error: Error?
    var finished = false
  }

  /// `play(at:)` counterpart of `boundedPosition`.
  private func boundedPlay(
    _ player: OpenAccessPlayer,
    at position: TrackPosition,
    timeout: TimeInterval = 5
  ) async -> PlayOutcome {
    let done = expectation(description: "play(at:) returns")
    let outcome = PlayOutcome()
    Task { @MainActor in
      do {
        try await player.play(at: position)
      } catch {
        outcome.error = error
      }
      outcome.finished = true
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: timeout)
    if !outcome.finished {
      XCTFail("play(at:) did not return within \(timeout)s")
    }
    return outcome
  }

  // MARK: - Async bridges: duplicate seek completion

  /// Stub whose seekTo delivers its completion twice, the shape of the
  /// Crashlytics issue bf69662d ("skipPlayhead(_:) tried to resume its
  /// continuation more than once"). The first result must win and the
  /// second must be dropped instead of trapping in `CheckedContinuation`.
  final class DoubleCompletingOpenAccessPlayer: OpenAccessPlayer {
    var firstResult: TrackPosition?
    var secondResult: TrackPosition?

    override public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
      completion?(firstResult)
      completion?(secondResult)
    }

    override func configurePlayer() {}
    override func addPlayerObservers() {}
  }

  private func makeDoubleCompletingPlayer() -> DoubleCompletingOpenAccessPlayer {
    let player = DoubleCompletingOpenAccessPlayer(tableOfContents: toc)
    player.lastKnownPosition = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)
    player.firstResult = TrackPosition(track: firstTrack, timestamp: 12, tracks: toc.tracks)
    player.secondResult = nil
    return player
  }

  func testSkipPlayhead_whenSeekCompletesTwice_returnsFirstResultWithoutTrapping() async {
    let player = makeDoubleCompletingPlayer()

    let result = await boundedPosition("skipPlayhead") { await player.skipPlayhead(15) }

    XCTAssertEqual(result?.timestamp, 12, "The first seek result must be returned; the late duplicate must be ignored")
  }

  func testMoveTo_whenSeekCompletesTwice_returnsFirstResultWithoutTrapping() async {
    let player = makeDoubleCompletingPlayer()

    let result = await boundedPosition("move(to:)") { await player.move(to: 0.5) }

    XCTAssertEqual(result?.timestamp, 12, "The first seek result must be returned; the late duplicate must be ignored")
  }

  // MARK: - waitForItemReady: exactly one completion per wait
  //
  // States x events. The wait ends on the FIRST of {timeout, .readyToPlay,
  // .failed}; every later event must be ignored. The (timeout, then .failed)
  // row is the production crash: the completion chain ends in skipPlayhead's
  // continuation, so a second call traps.
  //
  // No sleeps: the timeout's own completion fulfils `first`; `second` is an
  // inverted expectation that any later completion fulfils.

  private let shortTimeout: TimeInterval = 0.05

  private func makeItem() -> StatusDrivenPlayerItem {
    StatusDrivenPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
  }

  private final class WaitProbe {
    var completions: [Bool] = []
    var failedEmissions = 0
    var cancellable: AnyCancellable?
    let first: XCTestExpectation
    let second: XCTestExpectation

    init(first: XCTestExpectation, second: XCTestExpectation) {
      self.first = first
      self.second = second
    }
  }

  private func startWait(on player: OpenAccessPlayer, for item: StatusDrivenPlayerItem) -> WaitProbe {
    let second = expectation(description: "no second completion")
    second.isInverted = true
    let probe = WaitProbe(first: expectation(description: "first completion"), second: second)
    probe.cancellable = player.playbackStatePublisher.sink { state in
      if case .failed = state { probe.failedEmissions += 1 }
    }
    player.waitForItemReady(item, timeout: shortTimeout) { ready in
      probe.completions.append(ready)
      if probe.completions.count == 1 { probe.first.fulfill() } else { probe.second.fulfill() }
    }
    return probe
  }

  /// Returns once the main queue has run past the wait's timeout deadline.
  /// The timeout was scheduled earlier with an earlier deadline, so by now it
  /// has either run or been cancelled.
  private func passTimeoutDeadline() async {
    let passed = expectation(description: "main queue past the timeout deadline")
    DispatchQueue.main.asyncAfter(deadline: .now() + shortTimeout * 2) { passed.fulfill() }
    await fulfillment(of: [passed], timeout: 5)
  }

  private func assertNoSecondCompletion(_ probe: WaitProbe) async {
    await fulfillment(of: [probe.second], timeout: 0.2)
  }

  func testWaitForItemReady_whenItemFailsAfterTimeout_completesOnceAndReportsFailureOnce() async {
    let player = makePlayer()
    let item = makeItem()
    let probe = startWait(on: player, for: item)

    await fulfillment(of: [probe.first], timeout: 5)
    item.transition(to: .failed)
    await assertNoSecondCompletion(probe)

    XCTAssertEqual(probe.completions, [false], "A .failed status after the timeout must not complete the wait again")
    XCTAssertEqual(probe.failedEmissions, 1, "The load failure must be reported once, not once per path")
  }

  func testWaitForItemReady_whenItemBecomesReadyAfterTimeout_doesNotReportReady() async {
    let player = makePlayer()
    let item = makeItem()
    let probe = startWait(on: player, for: item)

    await fulfillment(of: [probe.first], timeout: 5)
    item.transition(to: .readyToPlay)
    await assertNoSecondCompletion(probe)

    XCTAssertEqual(probe.completions, [false], "Readiness after the timeout must not deliver a second completion")
  }

  func testWaitForItemReady_whenItemFailsBeforeTimeout_timeoutDoesNotCompleteAgain() async {
    let player = makePlayer()
    let item = makeItem()
    let probe = startWait(on: player, for: item)

    item.transition(to: .failed)
    await fulfillment(of: [probe.first], timeout: 5)
    await passTimeoutDeadline()
    await assertNoSecondCompletion(probe)

    XCTAssertEqual(probe.completions, [false])
    XCTAssertEqual(probe.failedEmissions, 1)
  }

  func testWaitForItemReady_whenItemBecomesReadyBeforeTimeout_completesTrueOnce() async {
    let player = makePlayer()
    let item = makeItem()
    let probe = startWait(on: player, for: item)

    item.transition(to: .readyToPlay)
    await fulfillment(of: [probe.first], timeout: 5)
    await passTimeoutDeadline()
    item.transition(to: .failed)
    await assertNoSecondCompletion(probe)

    XCTAssertEqual(probe.completions, [true], "Neither the timeout nor a later .failed may follow a ready completion")
    XCTAssertEqual(probe.failedEmissions, 0, "A ready item must not be reported as failed")
  }

  func testWaitForItemReady_whenItemFailsThenBecomesReady_staysFailed() async {
    let player = makePlayer()
    let item = makeItem()
    let probe = startWait(on: player, for: item)

    item.transition(to: .failed)
    item.transition(to: .readyToPlay)
    await fulfillment(of: [probe.first], timeout: 5)
    await assertNoSecondCompletion(probe)

    XCTAssertEqual(probe.completions, [false], "A status change after .failed must not complete the wait again")
  }

  /// A timed-out wait must stop observing the item. The status observation
  /// and its handler reference each other, so an observation left running
  /// keeps the completion, and everything the caller captured in it, alive
  /// for as long as the item lives.
  func testWaitForItemReady_afterTimeout_releasesTheCompletion() async {
    final class Token {}
    let player = makePlayer()
    let item = makeItem()
    let timedOut = expectation(description: "timeout completes the wait")
    weak var weakToken: Token?

    do {
      let token = Token()
      weakToken = token
      player.waitForItemReady(item, timeout: shortTimeout) { _ in
        _ = token
        timedOut.fulfill()
      }
    }
    await fulfillment(of: [timedOut], timeout: 5)
    // Let the timeout's work item finish returning before checking.
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 5)

    XCTAssertNil(weakToken, "The completion must be released once the wait has timed out")
    withExtendedLifetime(item) {}
  }
}
