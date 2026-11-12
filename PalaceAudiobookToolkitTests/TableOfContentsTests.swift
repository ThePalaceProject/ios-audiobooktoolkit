//
//  TableOfContentsTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/15/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
class TableOfContentsTests: XCTestCase {
  private let testID = "testID"

  // MARK: - Basic TOC Loading Tests
  
  func testTableOfContentsWithManifests() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try loadManifest(for: manifestJSON)
        let tableOfContents = AudiobookTableOfContents(
          manifest: manifest,
          tracks: Tracks(manifest: manifest, audiobookID: testID, token: nil)
        )
        XCTAssertFalse(tableOfContents.toc.isEmpty, "TOC should not be empty for \(manifestJSON.rawValue)")

        if let firstChapter = tableOfContents.toc.first {
          XCTAssertFalse(
            firstChapter.title.isEmpty,
            "First chapter title should not be empty in \(manifestJSON.rawValue)"
          )
        }
      } catch {
        XCTFail("Decoding failed for \(manifestJSON.rawValue) with error: \(error)")
      }
    }
  }

  func testChapterCounts() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try loadManifest(for: manifestJSON)
        let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
        let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        let expectedCount = manifestJSON.chapterCount
        XCTAssertEqual(
          tableOfContents.toc.count,
          expectedCount,
          "Expected \(expectedCount) chapters in \(manifestJSON.rawValue), but found \(tableOfContents.toc.count)"
        )
      } catch {
        XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
      }
    }
  }

  // MARK: - First Chapter Title Tests
  
  func testFirstChapterHasTitle() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try loadManifest(for: manifestJSON)
        let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
        let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        XCTAssertNotNil(
          tableOfContents.toc.first,
          "TOC should have at least one chapter in \(manifestJSON.rawValue)"
        )
        
        if let firstChapter = tableOfContents.toc.first {
          XCTAssertFalse(
            firstChapter.title.isEmpty,
            "First chapter should have a non-empty title in \(manifestJSON.rawValue)"
          )
        }
      } catch {
        XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
      }
    }
  }

  // MARK: - Chapter Navigation Tests
  
  func testNextChapterNavigation() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try loadManifest(for: manifestJSON)
        let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
        let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        guard toc.toc.count >= 2 else { continue }
        
        let firstChapter = toc.toc[0]
        let secondChapter = toc.toc[1]
        
        let nextChapter = toc.nextChapter(after: firstChapter)
        XCTAssertEqual(
          nextChapter?.title,
          secondChapter.title,
          "Next chapter after first should be second in \(manifestJSON.rawValue)"
        )
      } catch {
        XCTFail("Error for \(manifestJSON.rawValue): \(error)")
      }
    }
  }
  
  func testPreviousChapterNavigation() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try loadManifest(for: manifestJSON)
        let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
        let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

        guard toc.toc.count >= 2 else { continue }
        
        let firstChapter = toc.toc[0]
        let secondChapter = toc.toc[1]
        
        let prevChapter = toc.previousChapter(before: secondChapter)
        XCTAssertEqual(
          prevChapter?.title,
          firstChapter.title,
          "Previous chapter before second should be first in \(manifestJSON.rawValue)"
        )
      } catch {
        XCTFail("Error for \(manifestJSON.rawValue): \(error)")
      }
    }
  }
  
  func testLastChapterHasNoNext() {
    // Test with a known manifest that has a clear chapter structure
    do {
      let manifest = try loadManifest(for: .dungeonCrawlerCarl)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

      guard let lastChapter = toc.toc.last else {
        XCTFail("TOC should have chapters")
        return
      }
      
      let nextChapter = toc.nextChapter(after: lastChapter)
      XCTAssertNil(nextChapter, "Last chapter should have no next chapter")
    } catch {
      XCTFail("Error loading manifest: \(error)")
    }
  }

  // MARK: - PP-3518 Multi-Chapter Same Track Tests (Dungeon Crawler Carl Bug)
  
  /// Tests that multiple chapters on the same track are correctly identified.
  /// This is the core test for the PP-3518 bug fix.
  func testMultiChapterSameTrack_ChapterIdentification() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Verify we have the expected chapter structure
    XCTAssertEqual(toc.toc.count, 7, "Should have 7 chapters")
    
    // Part I and Chapter 2 share track 003 (0f4397a5-...)
    let partI = toc.toc[2]
    let chapter2 = toc.toc[3]
    
    XCTAssertEqual(partI.title, "Part I")
    XCTAssertEqual(chapter2.title, "Chapter 2")
    
    // Verify they share the same track
    XCTAssertEqual(
      partI.position.track.key,
      chapter2.position.track.key,
      "Part I and Chapter 2 should share the same track"
    )
    
    // Verify Part I starts before Chapter 2
    XCTAssertLessThan(
      partI.position.timestamp,
      chapter2.position.timestamp,
      "Part I should start before Chapter 2"
    )
  }
  
  /// Tests chapter lookup for positions in the middle of chapters (clear cases).
  func testChapterForPosition_MidChapter() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Test a position clearly in Chapter 2 (t=100, well after t=3 start)
    let chapter2 = toc.toc[3] // Chapter 2 starts at t=3
    let midChapter2Position = TrackPosition(
      track: chapter2.position.track,
      timestamp: 100.0,  // Clearly within Chapter 2
      tracks: tracks
    )
    
    let foundChapter = try toc.chapter(forPosition: midChapter2Position)
    XCTAssertEqual(foundChapter.title, "Chapter 2", "Position at t=100 should be in Chapter 2")
  }
  
  /// Tests that position at track end returns the correct chapter.
  /// This is the key test for PP-3518 - when track 003 ends, we should be in Chapter 2.
  func testChapterForPosition_AtTrackEnd() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Track 003 has duration 1409s. At the end of this track, we should be in Chapter 2.
    let chapter2 = toc.toc[3]
    let trackDuration = chapter2.position.track.duration
    
    let atTrackEnd = TrackPosition(
      track: chapter2.position.track,
      timestamp: trackDuration,
      tracks: tracks
    )
    
    let foundChapter = try toc.chapter(forPosition: atTrackEnd)
    XCTAssertEqual(
      foundChapter.title,
      "Chapter 2",
      "Position at end of track 003 (t=\(trackDuration)) should be in Chapter 2, not Part I"
    )
  }
  
  /// Tests that nextChapter works correctly for multi-chapter same track.
  func testMultiChapterSameTrack_NextChapterNavigation() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    let partI = toc.toc[2]
    let chapter2 = toc.toc[3]
    let chapter3 = toc.toc[4]
    
    // Next after Part I should be Chapter 2
    let nextAfterPartI = toc.nextChapter(after: partI)
    XCTAssertEqual(nextAfterPartI?.title, "Chapter 2")
    
    // Next after Chapter 2 should be Chapter 3
    let nextAfterChapter2 = toc.nextChapter(after: chapter2)
    XCTAssertEqual(nextAfterChapter2?.title, "Chapter 3")
    
    // Chapter 3 should be on a different track
    XCTAssertNotEqual(
      chapter2.position.track.key,
      chapter3.position.track.key,
      "Chapter 3 should be on a different track than Chapter 2"
    )
  }
  
  // MARK: - Track Consistency Tests
  
  func testTrackIndexConsistency() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      // Verify track indices match array positions
      for (arrayIndex, track) in tracks.tracks.enumerated() {
        XCTAssertEqual(
          track.index,
          arrayIndex,
          "Track index mismatch in \(manifestJSON.rawValue): track.index=\(track.index), arrayIndex=\(arrayIndex)"
        )
      }
    }
  }
  
  func testNextTrackNavigation() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      guard tracks.tracks.count >= 2 else { continue }
      
      let firstTrack = tracks.tracks[0]
      let secondTrack = tracks.tracks[1]
      
      let nextTrack = tracks.nextTrack(firstTrack)
      XCTAssertEqual(
        nextTrack?.key,
        secondTrack.key,
        "Next track after first should be second in \(manifestJSON.rawValue)"
      )
    }
  }
  
  func testLastTrackHasNoNext() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      guard let lastTrack = tracks.tracks.last else { continue }
      
      let nextTrack = tracks.nextTrack(lastTrack)
      XCTAssertNil(nextTrack, "Last track should have no next track in \(manifestJSON.rawValue)")
    }
  }

  // MARK: - Helper Methods

  func loadManifest(for json: ManifestJSON) throws -> Manifest {
    try Manifest.from(
      jsonFileName: json.rawValue,
      bundle: Bundle(for: type(of: self))
    )
  }
}

// MARK: - Indexed chapter lookup

/// `chapter(forPosition:)` answers from a sorted index; these tests compare it
/// with the linear scan it replaced, kept below as `referenceChapter`, so a
/// boundary rule (PP-4948, PP-4951) cannot drift without a failure here.
@MainActor
final class ChapterLookupIndexTests: XCTestCase {
  /// Every fixture, every chapter boundary and a grid inside every track, both
  /// tie-breaks: the indexed lookup returns the chapter the linear scan returns.
  func testIndexedLookup_matchesLinearScan_acrossFixturesAndBoundaries() throws {
    var comparisons = 0
    var indexedFixtures = 0
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
      let tracks = Tracks(manifest: manifest, audiobookID: "index-\(manifestJSON.rawValue)", token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      if toc.isChapterLookupIndexed { indexedFixtures += 1 }

      for position in Self.probePositions(toc) {
        for prefer in [false, true] {
          let expected = try? Self.referenceChapter(in: toc.toc, forPosition: position, preferChapterEndingHere: prefer)
          let actual = try? toc.chapter(forPosition: position, preferChapterEndingHere: prefer)
          XCTAssertEqual(
            actual?.id, expected?.id,
            "\(manifestJSON.rawValue) track \(position.track.index) @ \(position.timestamp) prefer=\(prefer): indexed '\(actual?.title ?? "nil")' vs linear '\(expected?.title ?? "nil")'"
          )
          comparisons += 1
        }
      }
    }
    XCTAssertGreaterThan(indexedFixtures, ManifestJSON.allCases.count / 2, "Most fixtures must use the index, or this compares the scan with itself.")
    XCTAssertGreaterThan(comparisons, 10_000)
  }

  /// A stored end that overshoots the next start by rounding is the case a
  /// binary search over starts would answer differently; the index refuses it.
  func testIndex_isNotBuilt_whenAChapterEndPassesTheNextStart() throws {
    var toc = try Self.makeTOC(.alice)
    let next = toc.toc[1].position
    toc.toc[0].endPosition = TrackPosition(track: next.track, timestamp: next.timestamp + 1e-9, tracks: next.tracks)
    toc.rebuildChapterIndex()

    XCTAssertFalse(toc.isChapterLookupIndexed)
    let atNextStart = try toc.chapter(forPosition: next)
    XCTAssertEqual(atNextStart.id, toc.toc[0].id, "Linear scan returns the first match, the overlapping chapter.")
  }

  func testIndex_isNotBuilt_whenStartsAreOutOfOrder() throws {
    var toc = try Self.makeTOC(.alice)
    toc.toc.swapAt(1, 2)
    toc.rebuildChapterIndex()
    XCTAssertFalse(toc.isChapterLookupIndexed)
  }

  /// The last chapter's track keeps its id but claims a later index, so the
  /// list stays in order and only the id check can refuse it.
  func testIndex_isNotBuilt_whenATrackIDMapsToTwoIndexes() throws {
    var toc = try Self.makeTOC(.alice)
    let last = toc.toc.count - 1
    let original = toc.toc[last].position
    let impostor = try Self.makeTrack(like: original.track, in: toc, index: original.track.index + 100, key: original.track.key)
    toc.toc[last].position = TrackPosition(track: impostor, timestamp: original.timestamp, tracks: original.tracks)
    toc.rebuildChapterIndex()
    XCTAssertFalse(toc.isChapterLookupIndexed)
  }

  /// A different track claims the last chapter track's index; the order holds
  /// (equal indexes compare as neither smaller), so only the index check can
  /// refuse it.
  func testIndex_isNotBuilt_whenAnIndexMapsToTwoTrackIDs() throws {
    var toc = try Self.makeTOC(.alice)
    let last = toc.toc.count - 1
    let original = toc.toc[last].position
    let impostor = try Self.makeTrack(like: original.track, in: toc, index: original.track.index, key: "impostor-key")
    toc.toc[last].position = TrackPosition(track: impostor, timestamp: original.timestamp, tracks: original.tracks)
    toc.rebuildChapterIndex()
    XCTAssertFalse(toc.isChapterLookupIndexed)
  }

  func testIndex_isNotBuilt_whenAChapterStartIsNaN() throws {
    var toc = try Self.makeTOC(.alice)
    toc.toc[3].position.timestamp = .nan
    toc.rebuildChapterIndex()
    XCTAssertFalse(toc.isChapterLookupIndexed)
  }

  /// Without stored ends (Findaway and Overdrive lists) a chapter ends where
  /// the next one starts, whatever its own duration says.
  func testIndexedLookup_withoutStoredEnds_matchesLinearScan() throws {
    var toc = try Self.makeTOC(.alice)
    for index in toc.toc.indices {
      toc.toc[index].endPosition = nil
      toc.toc[index].duration = 1.0
    }
    toc.rebuildChapterIndex()
    XCTAssertTrue(toc.isChapterLookupIndexed)

    for position in Self.probePositions(toc) {
      let expected = try? Self.referenceChapter(in: toc.toc, forPosition: position, preferChapterEndingHere: false)
      let actual = try? toc.chapter(forPosition: position)
      XCTAssertEqual(actual?.id, expected?.id, "track \(position.track.index) @ \(position.timestamp)")
    }
  }

  func testIndex_isNotBuilt_forEmptyTOC() throws {
    var toc = try Self.makeTOC(.alice)
    toc.toc = []
    toc.rebuildChapterIndex()
    XCTAssertFalse(toc.isChapterLookupIndexed)
    XCTAssertThrowsError(try toc.chapter(forPosition: Self.probePositions(try Self.makeTOC(.alice))[0]))
  }

  /// Changing the list after load drops the index, so a lookup cannot answer
  /// from the old order.
  func testEditingTOC_dropsIndex_andLookupFollowsTheNewList() throws {
    var toc = try Self.makeTOC(.alice)
    XCTAssertTrue(toc.isChapterLookupIndexed)
    let probe = toc.toc[3].position
    toc.toc.remove(at: 3)

    XCTAssertFalse(toc.isChapterLookupIndexed)
    let expected = try Self.referenceChapter(in: toc.toc, forPosition: probe, preferChapterEndingHere: false)
    XCTAssertEqual(try toc.chapter(forPosition: probe).id, expected.id)
  }

  /// A position whose track id is known under another index is outside the
  /// order the index relies on; the lookup must still match the scan.
  func testLookup_withInconsistentPositionTrack_matchesLinearScan() throws {
    let toc = try Self.makeTOC(.alice)
    let original = toc.toc[4].position
    let impostor = try XCTUnwrap(TrackFactory.createTrack(
      from: toc.manifest, title: nil, urlString: original.track.urls?.first?.absoluteString, audiobookID: "index",
      index: 0, duration: original.track.duration, token: nil, key: original.track.key
    ))
    for timestamp in [0.0, 1.0, original.track.duration - 0.2, Double.nan] {
      let position = TrackPosition(track: impostor, timestamp: timestamp, tracks: original.tracks)
      let expected = try? Self.referenceChapter(in: toc.toc, forPosition: position, preferChapterEndingHere: false)
      XCTAssertEqual((try? toc.chapter(forPosition: position))?.id, expected?.id, "timestamp \(timestamp)")
    }
  }

  // MARK: - Memoized lookup

  /// The memo answers what the lookup answers, whatever order positions are
  /// asked in: repeats, back-and-forth, and equal timestamps on different tracks.
  func testMemoizedLookup_matchesLookup_acrossFixtures_inAnyOrder() throws {
    var comparisons = 0
    for manifestJSON in ManifestJSON.allCases {
      let toc = try Self.makeTOC(manifestJSON)
      let probes = Self.probePositions(toc)
      let byTimestamp = probes.sorted { $0.timestamp < $1.timestamp }
      for order in [probes, byTimestamp] {
        var previous: TrackPosition?
        for position in order {
          for asked in [position, previous ?? position, position] {
            let expected = try? toc.chapter(forPosition: asked)
            XCTAssertEqual(
              toc.memoizedChapter(forPosition: asked)?.id, expected?.id,
              "\(manifestJSON.rawValue) track \(asked.track.index) @ \(asked.timestamp)"
            )
            comparisons += 1
          }
          previous = position
        }
      }
    }
    XCTAssertGreaterThan(comparisons, 10_000)
  }

  /// Asking for the position last asked costs no lookup; a different track or
  /// timestamp costs one.
  func testMemoizedLookup_looksUpOnlyWhenThePositionChanges() throws {
    let toc = try Self.makeTOC(.alice)
    let first = toc.toc[1].position + 5
    let otherTrack = TrackPosition(track: toc.toc[2].position.track, timestamp: first.timestamp, tracks: toc.tracks)
    let otherTime = first + 1

    let before = toc.chapterLookupCount
    _ = toc.memoizedChapter(forPosition: first)
    _ = toc.memoizedChapter(forPosition: first)
    let afterRepeat = toc.chapterLookupCount
    let onOtherTrack = toc.memoizedChapter(forPosition: otherTrack)
    let atOtherTime = toc.memoizedChapter(forPosition: otherTime)

    XCTAssertEqual(afterRepeat - before, 1)
    XCTAssertEqual(toc.chapterLookupCount - before, 3)
    XCTAssertEqual(onOtherTrack?.id, toc.toc[2].id)
    XCTAssertEqual(atOtherTime?.id, toc.toc[1].id)
  }

  /// A track that shares another's key under a different index, or a position
  /// on another track list, is a different question from the memo's last one.
  func testMemoizedLookup_sameKeyOtherIndexOrTrackList_matchesLookup() throws {
    let toc = try Self.makeTOC(.alice)
    let real = toc.toc[4].position + 1
    let impostor = try Self.makeTrack(like: real.track, in: toc, index: 0, key: real.track.key)
    let onImpostor = TrackPosition(track: impostor, timestamp: real.timestamp, tracks: real.tracks)
    let otherList = try Self.makeTOC(.alice).tracks
    let onOtherList = TrackPosition(track: real.track, timestamp: real.timestamp, tracks: otherList)

    for asked in [real, onImpostor, real, onOtherList, real] {
      let before = toc.chapterLookupCount
      let answer = toc.memoizedChapter(forPosition: asked)
      XCTAssertEqual(toc.chapterLookupCount - before, 1, "track index \(asked.track.index)")
      XCTAssertEqual(answer?.id, (try? toc.chapter(forPosition: asked))?.id)
    }
  }

  /// A copy whose list changes answers from its new list, not from the memo the
  /// original filled; the original keeps its own answer.
  func testMemoizedLookup_afterEditingACopy_followsEachCopysList() throws {
    let original = try Self.makeTOC(.alice)
    let probe = original.toc[3].position + 1
    XCTAssertEqual(original.memoizedChapter(forPosition: probe)?.id, original.toc[3].id)

    var edited = original
    edited.toc.remove(at: 3)
    let expected = try Self.referenceChapter(in: edited.toc, forPosition: probe, preferChapterEndingHere: false)

    XCTAssertNotEqual(expected.id, original.toc[3].id)
    XCTAssertEqual(edited.memoizedChapter(forPosition: probe)?.id, expected.id)
    edited.rebuildChapterIndex()
    XCTAssertEqual(edited.memoizedChapter(forPosition: probe)?.id, expected.id)
    XCTAssertEqual(original.memoizedChapter(forPosition: probe)?.id, original.toc[3].id)
  }

  /// A position with no chapter stays nil when asked again.
  func testMemoizedLookup_forEmptyList_isNilEveryTime() throws {
    var toc = try Self.makeTOC(.alice)
    let probe = toc.toc[0].position
    toc.toc = []
    toc.rebuildChapterIndex()

    XCTAssertNil(toc.memoizedChapter(forPosition: probe))
    XCTAssertNil(toc.memoizedChapter(forPosition: probe))
  }

  // MARK: - Helpers

  private static func makeTrack(like track: any Track, in toc: AudiobookTableOfContents, index: Int, key: String) throws -> any Track {
    try XCTUnwrap(TrackFactory.createTrack(
      from: toc.manifest, title: nil, urlString: track.urls?.first?.absoluteString, audiobookID: "index",
      index: index, duration: track.duration, token: nil, key: key
    ))
  }

  private static func makeTOC(_ json: ManifestJSON) throws -> AudiobookTableOfContents {
    let manifest = try Manifest.from(jsonFileName: json.rawValue, bundle: Bundle(for: ChapterLookupIndexTests.self))
    return AudiobookTableOfContents(manifest: manifest, tracks: Tracks(manifest: manifest, audiobookID: "index", token: nil))
  }

  /// Chapter starts and ends with offsets either side of the 0.1 s equality and
  /// 0.5 s end tolerances, plus a grid and out-of-range points on every track.
  private static func probePositions(_ toc: AudiobookTableOfContents) -> [TrackPosition] {
    let tracks = toc.tracks
    var positions: [TrackPosition] = []
    let nudges = [-1.0, -0.51, -0.5, -0.49, -0.1, -0.05, -1e-9, 0, 1e-9, 0.05, 0.1, 0.49, 0.5, 0.51, 1.0]
    var anchors: [TrackPosition] = []
    for (index, chapter) in toc.toc.enumerated() {
      anchors.append(chapter.position)
      if let end = chapter.endPosition { anchors.append(end) }
      if index + 1 == toc.toc.count {
        anchors.append(chapter.position + (chapter.duration ?? chapter.position.track.duration))
      }
    }
    for anchor in anchors {
      for nudge in nudges {
        positions.append(TrackPosition(track: anchor.track, timestamp: anchor.timestamp + nudge, tracks: tracks))
      }
    }
    for track in tracks.tracks {
      let duration = track.duration
      for step in 0...40 {
        positions.append(TrackPosition(track: track, timestamp: duration * Double(step) / 40, tracks: tracks))
      }
      for timestamp in [-5.0, duration + 5, duration - 0.25, .infinity] {
        positions.append(TrackPosition(track: track, timestamp: timestamp, tracks: tracks))
      }
    }
    return positions
  }

  /// The linear scan as it stood before the index, kept as the oracle.
  private static func referenceChapter(
    in toc: [Chapter],
    forPosition position: TrackPosition,
    preferChapterEndingHere: Bool
  ) throws -> Chapter {
    for (index, chapter) in toc.enumerated() {
      let chapterStart = chapter.position
      let chapterDuration = chapter.duration ?? chapter.position.track.duration
      let isLastChapter = index + 1 >= toc.count

      let chapterEndPosition: TrackPosition
      if let endPos = chapter.endPosition {
        chapterEndPosition = endPos
      } else if !isLastChapter {
        chapterEndPosition = toc[index + 1].position
      } else {
        chapterEndPosition = chapter.position + chapterDuration
      }

      let isAfterStart = position >= chapterStart
      let isBeforeEnd = position < chapterEndPosition
      let isAtChapterEnd = (position.track.key == chapterEndPosition.track.key &&
                            abs(position.timestamp - chapterEndPosition.timestamp) < 0.5)

      if isAfterStart && (isBeforeEnd || ((isLastChapter || preferChapterEndingHere) && isAtChapterEnd)) {
        return chapter
      }
    }

    let closest = toc.min { chapter1, chapter2 in
      let dist1 = abs((try? position - chapter1.position) ?? Double.greatestFiniteMagnitude)
      let dist2 = abs((try? position - chapter2.position) ?? Double.greatestFiniteMagnitude)
      return dist1 < dist2
    }
    guard let closest else { throw ChapterError.noChapterFoundForPosition }
    return closest
  }
}
