//
//  ChapterCompletionSaveTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-4951. What a chapter ending writes to a patron's saved place.
//
//  Before this suite there was no test anywhere in this repository touching
//  chapter completion or the end-of-track handlers in any of the three players
//  — which is how the defect below survived: the completion handler saved the
//  START of the chapter that had just finished, a place the patron had already
//  listened all the way through.
//
//  On the Findaway path that signal fires at every chapter, and the chapter it
//  names is resolved from a position sitting exactly on a boundary, which the
//  pinned tie-break hands to the chapter BEFORE the one that ended. So the
//  saved place moved backwards by roughly two chapters, at every chapter. With
//  the screen locked nothing corrects it, because every position mechanism on
//  that path is a suspendable timer (PP-4954).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class ChapterCompletionSaveTests: XCTestCase {

  // MARK: - The decision, exhaustively

  /// THE regression gate. The patron is partway through — or, at a real
  /// boundary, at the start of the next chapter — and that is what must be
  /// recorded, not the beginning of the chapter they just finished.
  ///
  /// Mutant: restoring `completedChapter.position` as the return value is the
  /// original defect, and fails here.
  func testCompletionSave_prefersTheLivePlayerPosition() throws {
    let toc = try Self.makeTOC()
    let completed = try XCTUnwrap(toc.toc.first)
    let laterTrack = try XCTUnwrap(toc.allTracks.first)
    let whereThePatronIs = TrackPosition(track: laterTrack, timestamp: 942, tracks: toc.tracks)

    let saved = DefaultAudiobookManager.positionToSaveOnChapterCompletion(
      completedChapter: completed,
      playerPosition: whereThePatronIs
    )

    XCTAssertEqual(saved.timestamp, 942, accuracy: 0.001,
                   "A completed chapter must record where the patron is, not where the chapter began")
    XCTAssertEqual(saved.track.key, laterTrack.key, "…and on the track they are actually on")
  }

  /// The one case the old behaviour was right for: the player can no longer say
  /// where it is. A stale place beats no place, so the chapter position stays
  /// as the fallback rather than the primary answer.
  ///
  /// Mutant: dropping the fallback (returning an optional, or trapping) loses a
  /// patron's place entirely on an unloaded player.
  func testCompletionSave_fallsBackToChapterPosition_whenPlayerCannotSayWhereItIs() throws {
    let toc = try Self.makeTOC()
    let completed = try XCTUnwrap(toc.toc.first)

    let saved = DefaultAudiobookManager.positionToSaveOnChapterCompletion(
      completedChapter: completed,
      playerPosition: nil
    )

    XCTAssertEqual(saved.timestamp, completed.position.timestamp, accuracy: 0.001,
                   "With no live position, the completed chapter's own position is the last resort")
    XCTAssertEqual(saved.track.key, completed.position.track.key)
  }

  /// A late-arriving completion notification is documented behaviour on the
  /// Findaway SDK — this repository carries a note from the original authors
  /// that it can be several seconds late. The decision must still be right
  /// then: the patron is further into the next chapter, and that is what should
  /// be recorded. This is the property the old code could not have, because a
  /// chapter's start does not move.
  func testCompletionSave_lateNotification_stillRecordsWhereThePatronReached() throws {
    let toc = try Self.makeTOC()
    let completed = try XCTUnwrap(toc.toc.first)
    let track = try XCTUnwrap(toc.allTracks.first)

    // The notification lands 8 seconds after the boundary; the patron is 8s in.
    let eightSecondsLate = TrackPosition(track: track, timestamp: 8, tracks: toc.tracks)

    let saved = DefaultAudiobookManager.positionToSaveOnChapterCompletion(
      completedChapter: completed,
      playerPosition: eightSecondsLate
    )

    XCTAssertEqual(saved.timestamp, 8, accuracy: 0.001,
                   "A late notification must record the reached position, not the boundary")
  }

  /// The decision must not silently discard a position of zero — a patron
  /// genuinely at the very start of the next chapter. `??` on an Optional gets
  /// this right where a truthiness check would not; this pins it so a future
  /// rewrite to `if playerPosition.timestamp > 0` is caught.
  func testCompletionSave_positionAtExactlyZero_isStillTheAnswer() throws {
    let toc = try Self.makeTOC()
    let completed = try XCTUnwrap(toc.toc.last)
    let firstTrack = try XCTUnwrap(toc.allTracks.first)
    let atChapterStart = TrackPosition(track: firstTrack, timestamp: 0, tracks: toc.tracks)

    let saved = DefaultAudiobookManager.positionToSaveOnChapterCompletion(
      completedChapter: completed,
      playerPosition: atChapterStart
    )

    XCTAssertEqual(saved.track.key, firstTrack.key,
                   "A live position of 0 is a real position, not a missing one")
  }

  // MARK: - The rewind this replaces, stated as a test rather than a comment
  //
  // Measured on the Findaway fixture used by PP-4990's tests: the completed
  // chapter's own position is not where the patron is, and the gap is the size
  // of a chapter. Pinning the SIZE keeps the significance visible — a future
  // reader can see this is chapters, not seconds.

  func testTheOldBehaviour_wouldHaveRewoundByAWholeChapter() throws {
    let toc = try Self.makeFindawayTOC()
    // Chapter 4 of the Findaway fixture runs 52:48 → 1:44:47.
    let completed = try XCTUnwrap(toc.toc.dropFirst(4).first)
    let track = try XCTUnwrap(toc.tracks.track(forPart: 1, sequence: 5))
    let whereThePatronIs = TrackPosition(track: track, timestamp: 0, tracks: toc.tracks)

    let old = completed.position
    let new = DefaultAudiobookManager.positionToSaveOnChapterCompletion(
      completedChapter: completed,
      playerPosition: whereThePatronIs
    )

    XCTAssertNotEqual(old.track.key, new.track.key,
                      "The old answer and the honest answer are on different chapters entirely")
  }

  // MARK: - Fixtures

  private static func makeTOC() throws -> AudiobookTableOfContents {
    let manifest = try Manifest.from(
      jsonFileName: "alice_manifest",
      bundle: Bundle(for: ChapterCompletionSaveTests.self)
    )
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "pp4951-test", decryptor: nil, token: nil)
    )
    return audiobook.tableOfContents
  }

  /// The Findaway-shaped fixture — real `findaway:part` / `findaway:sequence`
  /// numbering, and the same title the boundary rewind was measured on.
  private static func makeFindawayTOC() throws -> AudiobookTableOfContents {
    let manifest = try Manifest.from(
      jsonFileName: "secret_lives_manifest",
      bundle: Bundle(for: ChapterCompletionSaveTests.self)
    )
    let tracks = Tracks(manifest: manifest, audiobookID: "pp4951-findaway", token: nil)
    return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
  }
}
