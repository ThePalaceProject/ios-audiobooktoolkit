//
//  SkipBurstCoalescingTests.swift
//  PalaceAudiobookToolkitTests
//
//  A tap arrives every 0.2-0.3s in a real burst while a streamed seek needs
//  seconds to land, so one seek per tap means none of them lands. A run of taps
//  becomes one trailing seek; a single tap is still seeked at once (PP-5401).
//

import AVFoundation
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class SkipBurstCoalescingTests: XCTestCase {

  /// Records every seek and holds every rebuild, so a test can count the seeks
  /// a run of taps actually cost.
  final class SeekCountingPlayer: OpenAccessPlayer {
    var seeksPerformed: [TrackPosition] = []
    var rebuildTargets: [TrackPosition] = []
    private var pendingRebuilds: [(Bool) -> Void] = []

    override func configurePlayer() {}
    override func addPlayerObservers() {}

    override func rebuildPlayerQueueAndNavigate(
      to trackPosition: TrackPosition?,
      shouldResumePlayback: Bool = true,
      completion: ((Bool) -> Void)? = nil
    ) {
      if let trackPosition { rebuildTargets.append(trackPosition) }
      pendingRebuilds.append { completion?($0) }
    }

    override func performSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
      seeksPerformed.append(position)
      completion?(position)
    }

    func releaseAllRebuilds(succeeded: Bool = true) {
      let waiting = pendingRebuilds
      pendingRebuilds = []
      waiting.forEach { $0(succeeded) }
    }

    var rebuildCount: Int { rebuildTargets.count }
  }

  private var toc: AudiobookTableOfContents!
  private var restingPosition: TrackPosition!

  override func setUp() async throws {
    try await super.setUp()
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "skip-burst", decryptor: nil, token: nil)
    )
    toc = audiobook.tableOfContents
    XCTAssertGreaterThanOrEqual(toc.allTracks.count, 3, "the fixture needs three tracks to skip across")
    restingPosition = TrackPosition(track: toc.allTracks[2], timestamp: 10, tracks: toc.tracks)
  }

  /// Resting 10 s into the third track with no queue, so a skip out of it takes
  /// the rebuild path, which is the path a cross-track skip burst takes.
  private func makePlayer(window: TimeInterval) -> SeekCountingPlayer {
    let player = SeekCountingPlayer(tableOfContents: toc)
    player.lastKnownPosition = restingPosition
    player.skipCoalesceWindow = window
    return player
  }

  @discardableResult
  private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(what)")
    return false
  }

  // MARK: - A single tap must not pay for the window

  /// One tap is seeked at once.
  ///
  /// The gathering window must not become latency on the most-used control: a
  /// patron who taps skip once should not wait for a burst that never comes.
  func test_aSingleTap_isSeekedWithoutWaitingForTheWindow() async {
    // A window far longer than this test is willing to wait, so a pass can only
    // mean the seek did not wait for it.
    let player = makePlayer(window: 30)

    let tap = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }

    XCTAssertEqual(player.rebuildTargets[0], restingPosition + -30)

    player.releaseAllRebuilds()
    _ = await tap.value
  }

  // MARK: - A run of taps costs one trailing seek

  /// Ten taps cost two seeks, not ten.
  ///
  /// The first is the immediate one above; the rest are gathered into a single
  /// trailing seek once the tapping stops.
  func test_aRunOfTaps_costsOneTrailingSeekRatherThanOnePerTap() async {
    let player = makePlayer(window: 0.05)

    var taps: [Task<TrackPosition?, Never>] = []
    taps.append(Task { await player.skipPlayhead(-30) })
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }

    for _ in 0 ..< 9 {
      taps.append(Task { await player.skipPlayhead(-30) })
    }

    guard await waitUntil("the trailing rebuild", { player.rebuildCount == 2 }) else { return }
    // Give any further seek a chance to appear before asserting there is none.
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(
      player.rebuildCount, 2,
      "ten taps must cost the first seek plus one trailing seek, not one each; targets were \(player.rebuildTargets)"
    )

    player.releaseAllRebuilds()
    for tap in taps { _ = await tap.value }
  }

  /// The trailing seek goes where the gathered taps add up to.
  ///
  /// `currentTrackPosition` reports the in-flight seek's target, so the
  /// gathered total applied to it lands where the last tap would have asked to
  /// go. Collapsing the seeks must not change the destination.
  func test_theTrailingSeek_landsWhereTheGatheredTapsAddUpTo() async {
    let player = makePlayer(window: 0.05)

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }

    let second = Task { await player.skipPlayhead(-30) }
    let third = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the trailing rebuild", { player.rebuildCount == 2 }) else { return }

    XCTAssertEqual(
      player.rebuildTargets[1], player.rebuildTargets[0] + -60,
      "two gathered taps of -30 must land 60s before the first tap's target"
    )

    player.releaseAllRebuilds()
    _ = await first.value
    _ = await second.value
    _ = await third.value
  }

  /// Every tap's caller is answered.
  ///
  /// The gathered taps are parked on continuations; one left unresumed traps the
  /// process, and a caller never answered hangs whatever is awaiting the skip.
  func test_everyGatheredTap_isAnswered() async {
    let player = makePlayer(window: 0.05)

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }
    let gathered = (0 ..< 4).map { _ in Task { await player.skipPlayhead(-30) } }

    guard await waitUntil("the trailing rebuild", { player.rebuildCount == 2 }) else { return }
    player.releaseAllRebuilds()

    _ = await first.value
    for tap in gathered {
      let landed = await tap.value
      XCTAssertNotNil(landed, "a gathered tap must be told where the seek landed")
    }
  }

  /// Tearing the player down answers the taps it is still holding.
  ///
  /// Without this the continuations are dropped, which traps rather than
  /// failing, so the symptom would be a dead test process and not a result.
  func test_unloading_answersTheTapsStillGathered() async {
    let player = makePlayer(window: 30)

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }
    let gathered = (0 ..< 3).map { _ in Task { await player.skipPlayhead(-30) } }
    // The taps are parked on the long window; nothing will seek them.
    try? await Task.sleep(nanoseconds: 100_000_000)

    player.unload()

    for tap in gathered {
      let landed = await tap.value
      XCTAssertNil(landed, "a tap dropped at teardown never seeked, so it has no position to report")
    }

    player.releaseAllRebuilds()
    _ = await first.value
  }

  /// Draining the gathered taps must not disturb the position the patron
  /// returns to.
  ///
  /// `currentTrackPosition` writes `lastKnownPosition` as a side effect, so a
  /// drain that asked it where the player was would overwrite the saved
  /// position during teardown. Caught by `EndObserverRetentionTests` after the
  /// first attempt did exactly that; pinned here too, next to the drain it is
  /// a property of.
  func test_unloading_withTapsGathered_leavesTheSavedPositionAlone() async {
    let player = makePlayer(window: 30)
    let saved = TrackPosition(track: toc.allTracks[0], timestamp: 42, tracks: toc.tracks)

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }
    let gathered = (0 ..< 3).map { _ in Task { await player.skipPlayhead(-30) } }
    try? await Task.sleep(nanoseconds: 100_000_000)

    // Set after the taps are parked, so only the drain could overwrite it.
    player.lastKnownPosition = saved
    player.unload()

    XCTAssertEqual(player.lastKnownPosition?.track.key, saved.track.key,
                   "teardown must not move the saved position to another track")
    XCTAssertEqual(player.lastKnownPosition?.timestamp, 42,
                   "teardown must not move the saved timestamp")

    for tap in gathered { _ = await tap.value }
    player.releaseAllRebuilds()
    _ = await first.value
  }

  // MARK: - Switched off

  /// With the window at zero every tap seeks, which is what the deterministic
  /// tests of the seek paths rely on.
  func test_withTheWindowOff_everyTapSeeks() async {
    let player = makePlayer(window: 0)

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.rebuildCount == 1 }) else { return }
    let second = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the second rebuild", { player.rebuildCount == 2 }) else { return }

    XCTAssertEqual(player.rebuildTargets[1], player.rebuildTargets[0] + -30)

    player.releaseAllRebuilds()
    _ = await first.value
    _ = await second.value
  }
}
