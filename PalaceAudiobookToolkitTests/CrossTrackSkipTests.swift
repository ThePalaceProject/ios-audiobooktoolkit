//
//  CrossTrackSkipTests.swift
//  PalaceAudiobookToolkitTests
//
//  A skip that lands in a track the queue does not hold rebuilds the queue.
//  Until that seek lands, the skip's target is the reported position, so a
//  second skip counts from it rather than from an item still loading
//  (PP-5401).
//

import AVFoundation
import Combine
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class CrossTrackSkipTests: XCTestCase {
  /// Holds each rebuild until the test releases it.
  final class RebuildRecordingPlayer: OpenAccessPlayer {
    var rebuildTargets: [TrackPosition] = []
    var pendingRebuilds: [(Bool) -> Void] = []
    var seeksPerformed: [TrackPosition] = []

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

    func releaseRebuild(at index: Int, succeeded: Bool = true) {
      pendingRebuilds[index](succeeded)
    }
  }

  private var toc: AudiobookTableOfContents!
  private var restingPosition: TrackPosition!

  override func setUp() async throws {
    try await super.setUp()
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "cross-track-skip", decryptor: nil, token: nil)
    )
    toc = audiobook.tableOfContents
    XCTAssertGreaterThanOrEqual(toc.allTracks.count, 3, "the fixture needs three tracks to skip across")
    restingPosition = TrackPosition(track: toc.allTracks[2], timestamp: 10, tracks: toc.tracks)
  }

  /// A player resting 10 s into the third track, with no queue, so every
  /// skip out of that track takes the rebuild path.
  private func makePlayer() -> RebuildRecordingPlayer {
    let player = RebuildRecordingPlayer(tableOfContents: toc)
    player.lastKnownPosition = restingPosition
    return player
  }

  /// Fails the test, rather than returning quietly, when the condition never holds.
  @discardableResult
  private func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(what)")
    return false
  }

  /// While the rebuild runs, the skip's target is the reported position.
  func testSkipAcrossTracks_whileTheRebuildRuns_reportsTheTarget() async {
    let player = makePlayer()

    let skip = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the rebuild", { player.pendingRebuilds.count == 1 }) else { return }

    XCTAssertEqual(player.currentTrackPosition, player.rebuildTargets[0])

    player.releaseRebuild(at: 0)
    _ = await skip.value
  }

  /// Once the seek lands the target is released, so the position is read from
  /// the player again rather than staying pinned to the skip.
  func testSkipAcrossTracks_onceTheSeekLands_releasesTheTarget() async {
    let player = makePlayer()

    let skip = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the rebuild", { player.pendingRebuilds.count == 1 }) else { return }
    player.releaseRebuild(at: 0)
    let landed = await skip.value

    XCTAssertEqual(landed, player.rebuildTargets[0])
    XCTAssertEqual(player.currentTrackPosition, restingPosition)
  }

  /// A rebuild that fails reports no position, seeks nowhere, and releases the
  /// target, so the next skip does not count from somewhere the player never went.
  func testSkipAcrossTracks_whenTheRebuildFails_releasesTheTargetAndReportsNothing() async {
    let player = makePlayer()

    let skip = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the rebuild", { player.pendingRebuilds.count == 1 }) else { return }
    player.releaseRebuild(at: 0, succeeded: false)
    let landed = await skip.value

    XCTAssertNil(landed)
    XCTAssertTrue(player.seeksPerformed.isEmpty)
    XCTAssertEqual(player.currentTrackPosition, restingPosition)
  }

  /// Two quick skips: the second counts from where the first is going. Counting
  /// from an item still loading is how repeated 30 s skips walked back a whole
  /// track each.
  func testSecondSkipDuringARebuild_countsFromTheFirstSkipsTarget() async {
    let player = makePlayer()

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.pendingRebuilds.count == 1 }) else { return }
    let second = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the second rebuild", { player.pendingRebuilds.count == 2 }) else { return }

    XCTAssertEqual(player.rebuildTargets[1], player.rebuildTargets[0] + -30)

    player.releaseRebuild(at: 0)
    player.releaseRebuild(at: 1)
    _ = await first.value
    _ = await second.value
  }

  /// The first skip landing must not release the second skip's target, or a
  /// third skip in that moment counts from the wrong place again. The second
  /// landing then releases its own.
  func testFirstSkipLanding_keepsTheSecondSkipsTargetUntilItLands() async {
    let player = makePlayer()

    let first = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the first rebuild", { player.pendingRebuilds.count == 1 }) else { return }
    let second = Task { await player.skipPlayhead(-30) }
    guard await waitUntil("the second rebuild", { player.pendingRebuilds.count == 2 }) else { return }

    player.releaseRebuild(at: 0)
    _ = await first.value
    XCTAssertEqual(player.currentTrackPosition, player.rebuildTargets[1])

    player.releaseRebuild(at: 1)
    _ = await second.value
    XCTAssertEqual(player.currentTrackPosition, restingPosition)
  }
}
