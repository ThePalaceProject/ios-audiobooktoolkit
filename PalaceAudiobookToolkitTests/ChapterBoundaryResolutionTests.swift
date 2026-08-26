//
//  ChapterBoundaryResolutionTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-4951, piece 1. What the boundary tie-break actually resolves to.
//
//  The end-of-track handlers decide "does the next track continue the same
//  chapter?" by resolving two positions and comparing them. Both resolutions go
//  through the SAME `preferChapterEndingHere` flag, so it is not obvious from
//  reading whether unpinning the flag changes the ANSWER or merely moves both
//  sides together. The ticket assumes the former; these tests establish which
//  it is, because the whole shape of the fix depends on it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class ChapterBoundaryResolutionTests: XCTestCase {

  /// A position at the very end of a track that closes a chapter, and a
  /// position at the very start of the next track, are the same instant in the
  /// book. The question is whether the tie-break makes them resolve to the same
  /// CHAPTER — because that comparison is what suppresses `.completed`.
  func testBoundary_pinned_bothSidesResolveTogether() throws {
    let toc = try Self.makeFindawayTOC()
    let (endedTrack, nextTrack) = try Self.adjacentChapterBoundaryTracks(toc)

    let endedPosition = TrackPosition(track: endedTrack, timestamp: endedTrack.duration, tracks: toc.tracks)
    let nextStart = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: toc.tracks)

    let ended = try? toc.chapter(forPosition: endedPosition, preferChapterEndingHere: true)
    let next = try? toc.chapter(forPosition: nextStart, preferChapterEndingHere: true)

    // Documented, not asserted-as-desirable: this is the CURRENT behaviour and
    // the reason `.completed` is unreachable mid-book on the AVPlayer paths.
    XCTAssertEqual(ended, next,
                   "Pinned: both sides resolve to the same chapter, so the handler always says 'continue'")
  }

  /// The load-bearing question. If unpinning moves both sides together, the
  /// comparison still says "continue" and unpinning alone changes nothing about
  /// whether `.completed` fires — which would make the ticket's plan wrong.
  func testBoundary_unpinned_whetherTheAnswerActuallyChanges() throws {
    let toc = try Self.makeFindawayTOC()
    let (endedTrack, nextTrack) = try Self.adjacentChapterBoundaryTracks(toc)

    let endedPosition = TrackPosition(track: endedTrack, timestamp: endedTrack.duration, tracks: toc.tracks)
    let nextStart = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: toc.tracks)

    let endedUnpinned = try? toc.chapter(forPosition: endedPosition)
    let nextUnpinned = try? toc.chapter(forPosition: nextStart)

    XCTAssertNotEqual(
      endedUnpinned, nextUnpinned,
      """
      Unpinning must make the two sides disagree at a chapter boundary — that \
      disagreement is the ONLY thing that lets the handler fall through to \
      `.completed`. If they still match, unpinning the flag does not switch \
      chapter completion on and the fix has to be shaped differently.
      """
    )
  }

  /// The asymmetric option, in case the symmetric one is a no-op: resolve the
  /// ended side as the chapter that ENDS at the boundary and the next side as
  /// the chapter that BEGINS there. That pairing names the finished chapter
  /// correctly AND makes the two sides differ.
  func testBoundary_asymmetric_namesTheFinishedChapterAndDiffers() throws {
    let toc = try Self.makeFindawayTOC()
    let (endedTrack, nextTrack) = try Self.adjacentChapterBoundaryTracks(toc)

    let endedPosition = TrackPosition(track: endedTrack, timestamp: endedTrack.duration, tracks: toc.tracks)
    let nextStart = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: toc.tracks)

    let finished = try? toc.chapter(forPosition: endedPosition, preferChapterEndingHere: true)
    let upcoming = try? toc.chapter(forPosition: nextStart)

    XCTAssertNotEqual(finished, upcoming,
                      "Asymmetric resolution must distinguish the finished chapter from the upcoming one")
    XCTAssertEqual(finished?.position.track.key, endedTrack.key,
                   "The finished chapter must be the one whose audio just ended")
  }

  // MARK: - Fixture

  private static func makeFindawayTOC() throws -> AudiobookTableOfContents {
    let manifest = try Manifest.from(
      jsonFileName: "secret_lives_manifest",
      bundle: Bundle(for: ChapterBoundaryResolutionTests.self)
    )
    let tracks = Tracks(manifest: manifest, audiobookID: "pp4951-boundary", token: nil)
    return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
  }

  /// Two adjacent tracks that sit on a real chapter boundary. On this fixture
  /// every chapter is one track, so any adjacent pair qualifies; picking a
  /// mid-book pair avoids the first and last chapters, which the tie-break
  /// treats specially (no predecessor / end-of-book tolerance).
  private static func adjacentChapterBoundaryTracks(
    _ toc: AudiobookTableOfContents
  ) throws -> (any Track, any Track) {
    let ended = try XCTUnwrap(toc.tracks.track(forPart: 1, sequence: 4))
    let next = try XCTUnwrap(toc.tracks.nextTrack(ended))
    return (ended, next)
  }
}
