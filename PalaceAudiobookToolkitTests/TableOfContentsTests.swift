//
//  TableOfContentsTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/15/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

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
