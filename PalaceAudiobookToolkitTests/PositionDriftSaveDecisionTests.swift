//
//  PositionDriftSaveDecisionTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-5033. The guard that decides whether a listening position has moved far
//  enough to be worth saving.
//
//  It subtracted two timestamps that are each measured from the start of their
//  OWN audio file, without checking the files match. Inside one file that is
//  correct. Across a boundary the arithmetic is meaningless, and it can discard a
//  patron's genuine movement as "no movement" — at exactly the moment a save is
//  most valuable, because the end of a chapter is a natural place to stop
//  listening.
//
//  `TrackPosition` already has a track-aware `-` operator that accumulates across
//  intervening tracks. The defect is that this one site bypassed it. That matters
//  for the shape of the fix: nothing shared changes, so the blast radius is this
//  decision alone. CLAUDE.md records what happens when a comparison helper in
//  this family IS changed — a fix correct in isolation, 225 green tests, and
//  playback would have paused at every chapter.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class PositionDriftSaveDecisionTests: XCTestCase {

  private let testID = "PP5033"

  /// Real multi-track fixture — the defect only exists across tracks, so a
  /// hand-built single-track stub could not express it.
  private func makeTracks() throws -> Tracks {
    let manifest = try Manifest.from(
      jsonFileName: ManifestJSON.secretLives.rawValue,
      bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    try XCTSkipUnless(tracks.tracks.count >= 2, "fixture must have at least two tracks")
    return tracks
  }

  private func position(_ tracks: Tracks, _ index: Int, _ timestamp: Double) -> TrackPosition {
    TrackPosition(track: tracks.tracks[index], timestamp: timestamp, tracks: tracks)
  }

  // MARK: - Within a single track (behaviour that must NOT change)

  func testSameTrack_movementBelowThreshold_isNotSaved() throws {
    let tracks = try makeTracks()
    XCTAssertFalse(
      AudiobookPlaybackModel.shouldSaveOnDrift(
        from: position(tracks, 0, 10.0), to: position(tracks, 0, 11.0)),
      "a 1s nudge inside one track is the write-throttling this guard exists for")
  }

  func testSameTrack_movementAboveThreshold_isSaved() throws {
    let tracks = try makeTracks()
    XCTAssertTrue(
      AudiobookPlaybackModel.shouldSaveOnDrift(
        from: position(tracks, 0, 10.0), to: position(tracks, 0, 20.0)),
      "10s of real movement inside one track must be saved")
  }

  func testNoPriorSave_isAlwaysSaved() throws {
    let tracks = try makeTracks()
    XCTAssertTrue(
      AudiobookPlaybackModel.shouldSaveOnDrift(from: nil, to: position(tracks, 0, 5.0)),
      "with nothing saved yet there is no drift to measure; the first position must land")
  }

  // MARK: - Across a track boundary (the defect)

  func testAcrossTracks_largeRealMovement_isSavedEvenWhenRawTimestampsAreClose() throws {
    // THE DEFECT, stated as the patron's situation: they were one second into
    // chapter one, and are now two and a half seconds into chapter two. The real
    // distance travelled is the whole remainder of track one plus 2.5s — minutes,
    // not seconds. Subtracting the raw timestamps gives |1.0 - 2.5| = 1.5, below
    // the 2s threshold, so the save was skipped as "no movement".
    let tracks = try makeTracks()
    let lastSaved = position(tracks, 0, 1.0)
    let candidate = position(tracks, 1, 2.5)

    let realMovement = try candidate - lastSaved
    XCTAssertGreaterThan(
      realMovement, 2.0,
      "precondition: the fixture must actually put these positions far apart in real time")
    XCTAssertLessThan(
      abs(lastSaved.timestamp - candidate.timestamp), 2.0,
      "precondition: and their RAW timestamps must be close, which is what fools the old guard")

    XCTAssertTrue(
      AudiobookPlaybackModel.shouldSaveOnDrift(from: lastSaved, to: candidate),
      "a position that moved into a different file has moved; it must be saved")
  }

  func testAcrossTracks_movingBackwards_isAlsoSaved() throws {
    // Symmetry: a skip-back across a boundary is movement too, and the operator
    // returns a negative difference there — a fix that forgot `abs` would drop it.
    let tracks = try makeTracks()
    XCTAssertTrue(
      AudiobookPlaybackModel.shouldSaveOnDrift(
        from: position(tracks, 1, 2.5), to: position(tracks, 0, 1.0)),
      "moving backwards across a boundary is still movement")
  }

  func testAcrossTracks_atTheSeam_isNotSavedBecauseNoTimeHasPassed() throws {
    // I asserted the opposite first, and the fix proved me wrong. Worth keeping
    // the corrected reasoning rather than just the corrected assertion.
    //
    // Crossing a boundary is not itself the thing worth saving — REAL MOVEMENT
    // is. A tenth of a second before the seam and the first moment after it are
    // a tenth of a second apart in the book, so the already-stored position is
    // still accurate to 0.1s and a write buys nothing. A patron who stops here
    // resumes 0.1s early, not a chapter early.
    //
    // This is the distinction the whole ticket turns on: the defect is not
    // "boundaries are skipped", it is "large real movement is MEASURED as small
    // when the file changes". Conflating the two would make this guard write on
    // every boundary crossing, which is the write-storm it exists to prevent.
    let tracks = try makeTracks()
    let endOfFirst = position(tracks, 0, tracks.tracks[0].duration - 0.1)
    let startOfSecond = position(tracks, 1, 0.0)

    let realMovement = try startOfSecond - endOfFirst
    XCTAssertLessThan(abs(realMovement), 2.0,
                      "precondition: the seam really is a small move in book time")
    XCTAssertFalse(
      AudiobookPlaybackModel.shouldSaveOnDrift(from: endOfFirst, to: startOfSecond),
      "a tenth of a second of real movement is not worth a write, boundary or not")
  }

  // MARK: - Degenerate inputs

  func testUnrelatedTracks_cannotBeCompared_andAreTreatedAsMovement() throws {
    // `TrackPosition.-` throws when a track is not in the other's `tracks` list.
    // The guard must fail TOWARD saving: the cost of being wrong here is one
    // redundant write, against losing a patron's place.
    let tracks = try makeTracks()
    let manifest = try Manifest.from(
      jsonFileName: ManifestJSON.flatland.rawValue,
      bundle: Bundle(for: type(of: self)))
    let otherTracks = Tracks(manifest: manifest, audiobookID: "PP5033-other", token: nil)
    try XCTSkipUnless(!otherTracks.tracks.isEmpty, "second fixture must have a track")

    let foreign = TrackPosition(
      track: otherTracks.tracks[0], timestamp: 1.0, tracks: otherTracks)

    XCTAssertTrue(
      AudiobookPlaybackModel.shouldSaveOnDrift(from: position(tracks, 0, 1.0), to: foreign),
      "an uncomparable pair must be saved, not silently discarded")
  }

  func testThresholdIsRespectedExactly() throws {
    // Boundary of the threshold itself: strictly greater, not >=. Pins the
    // comparison so a `>=` mutant is caught.
    let tracks = try makeTracks()
    XCTAssertFalse(
      AudiobookPlaybackModel.shouldSaveOnDrift(
        from: position(tracks, 0, 10.0), to: position(tracks, 0, 12.0), threshold: 2.0),
      "movement exactly equal to the threshold is not yet worth a write")
    XCTAssertTrue(
      AudiobookPlaybackModel.shouldSaveOnDrift(
        from: position(tracks, 0, 10.0), to: position(tracks, 0, 12.01), threshold: 2.0),
      "just over the threshold is")
  }
}
