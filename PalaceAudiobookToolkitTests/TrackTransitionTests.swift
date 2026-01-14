//
//  TrackTransitionTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Palace Team on 2026-01-14.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

/// Tests for track transition edge cases, specifically targeting the PP-3518 bug
/// where chapters were incorrectly identified at track boundaries.
final class TrackTransitionTests: XCTestCase {
  private let testID = "testID"
  
  // MARK: - Track End Position Tests
  
  /// Tests that `chapter(forPosition:)` returns the correct chapter at exact track duration.
  /// This is the critical path for AVPlayerItemDidPlayToEndTime handling.
  func testChapterAtExactTrackDuration_AllManifests() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      
      // Test each track's exact end position
      for track in tracks.tracks {
        let exactEndPosition = TrackPosition(
          track: track,
          timestamp: track.duration,
          tracks: tracks
        )
        
        // Should find a chapter and not throw
        do {
          let chapter = try toc.chapter(forPosition: exactEndPosition)
          XCTAssertNotNil(chapter, "Should find chapter at end of track \(track.index) in \(manifestJSON.rawValue)")
        } catch {
          XCTFail("Failed to find chapter at end of track \(track.index) in \(manifestJSON.rawValue): \(error)")
        }
      }
    }
  }
  
  /// Tests track transition from one track to the next across all manifests.
  func testTrackTransition_ToNextTrack() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      // Test each track except the last
      for (index, track) in tracks.tracks.enumerated() where index < tracks.tracks.count - 1 {
        let nextTrack = tracks.tracks[index + 1]
        
        // Get the next track using the Tracks method
        let foundNextTrack = tracks.nextTrack(track)
        
        XCTAssertNotNil(foundNextTrack, "Should find next track after track \(index) in \(manifestJSON.rawValue)")
        XCTAssertEqual(foundNextTrack?.key, nextTrack.key, "Next track should match expected in \(manifestJSON.rawValue)")
      }
    }
  }
  
  /// Tests that the last track has no next track.
  func testLastTrack_NoNextTrack() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      guard let lastTrack = tracks.tracks.last else {
        XCTFail("No tracks in \(manifestJSON.rawValue)")
        continue
      }
      
      let nextTrack = tracks.nextTrack(lastTrack)
      XCTAssertNil(nextTrack, "Last track should have no next track in \(manifestJSON.rawValue)")
    }
  }
  
  // MARK: - Multi-Chapter Same Track Tests (PP-3518)
  
  /// The core PP-3518 bug test: When track 003 ends, we should be in "Chapter 2",
  /// not "Part I", and the next chapter should be "Chapter 3".
  func testPP3518_TrackEndChapterIdentification() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Track 003 contains both "Part I" (t=1) and "Chapter 2" (t=3)
    // Its duration is 1409 seconds
    let track003 = tracks.tracks[2]  // 0-indexed, so track 003 is index 2
    
    // Simulate AVPlayerItemDidPlayToEndTime - player reports position at track duration
    let endOfTrackPosition = TrackPosition(
      track: track003,
      timestamp: track003.duration,
      tracks: tracks
    )
    
    // This MUST return "Chapter 2", NOT "Part I"
    let chapterAtEnd = try toc.chapter(forPosition: endOfTrackPosition)
    XCTAssertEqual(chapterAtEnd.title, "Chapter 2",
                   "PP-3518: At track 003 end, chapter should be 'Chapter 2', not '\(chapterAtEnd.title)'")
    
    // The next chapter MUST be "Chapter 3"
    let nextChapter = toc.nextChapter(after: chapterAtEnd)
    XCTAssertEqual(nextChapter?.title, "Chapter 3",
                   "PP-3518: After Chapter 2 ends, next chapter should be 'Chapter 3', not '\(nextChapter?.title ?? "nil")'")
  }
  
  /// Tests the exact boundary between two chapters on the same track.
  func testPP3518_ChapterBoundaryOnSameTrack() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    let partI = toc.toc[2]
    let chapter2 = toc.toc[3]
    
    // Verify same track
    XCTAssertEqual(partI.position.track.key, chapter2.position.track.key)
    
    // Part I: t=1 to t=3
    // Chapter 2: t=3 to track end
    
    // Just before boundary (t=2.9) should be Part I
    let justBeforeBoundary = TrackPosition(
      track: partI.position.track,
      timestamp: 2.9,
      tracks: tracks
    )
    let chapterJustBefore = try toc.chapter(forPosition: justBeforeBoundary)
    XCTAssertEqual(chapterJustBefore.title, "Part I", "t=2.9 should be in Part I")
    
    // At boundary (t=3.0) should be Chapter 2
    let atBoundary = TrackPosition(
      track: partI.position.track,
      timestamp: 3.0,
      tracks: tracks
    )
    let chapterAtBoundary = try toc.chapter(forPosition: atBoundary)
    XCTAssertEqual(chapterAtBoundary.title, "Chapter 2", "t=3.0 should be in Chapter 2")
    
    // Just after boundary (t=3.1) should be Chapter 2
    let justAfterBoundary = TrackPosition(
      track: partI.position.track,
      timestamp: 3.1,
      tracks: tracks
    )
    let chapterJustAfter = try toc.chapter(forPosition: justAfterBoundary)
    XCTAssertEqual(chapterJustAfter.title, "Chapter 2", "t=3.1 should be in Chapter 2")
  }
  
  /// Tests that all positions within a chapter are correctly identified.
  func testPP3518_FullChapterSweep() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    let chapter2 = toc.toc[3]
    let sharedTrack = chapter2.position.track
    
    // Sweep from Chapter 2 start to track end, all should be Chapter 2
    let chapter2Start = chapter2.position.timestamp  // t=3
    let trackEnd = sharedTrack.duration  // 1409
    
    // Test every 100 seconds
    var timestamp = chapter2Start
    while timestamp <= trackEnd {
      let position = TrackPosition(track: sharedTrack, timestamp: timestamp, tracks: tracks)
      let chapter = try toc.chapter(forPosition: position)
      XCTAssertEqual(chapter.title, "Chapter 2",
                     "Position at t=\(timestamp) should be in Chapter 2, not \(chapter.title)")
      timestamp += 100.0
    }
    
    // Also test exact end
    let endPosition = TrackPosition(track: sharedTrack, timestamp: trackEnd, tracks: tracks)
    let chapterAtEnd = try toc.chapter(forPosition: endPosition)
    XCTAssertEqual(chapterAtEnd.title, "Chapter 2",
                   "Position at track end (t=\(trackEnd)) should be in Chapter 2")
  }
  
  // MARK: - Cross-Track Chapter Boundary Tests
  
  /// Tests chapter transitions that cross track boundaries.
  func testCrossTrackChapterTransition() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Chapter 2 ends at end of track 003, Chapter 3 starts at track 004
    let chapter2 = toc.toc[3]
    let chapter3 = toc.toc[4]
    
    // End of Chapter 2's track
    let track003 = chapter2.position.track
    let endOfTrack003 = TrackPosition(track: track003, timestamp: track003.duration, tracks: tracks)
    
    // Start of Chapter 3's track
    let track004 = chapter3.position.track
    let startOfTrack004 = TrackPosition(track: track004, timestamp: 0.0, tracks: tracks)
    
    // At end of track 003, should still be in Chapter 2
    let chapterAtTrack003End = try toc.chapter(forPosition: endOfTrack003)
    XCTAssertEqual(chapterAtTrack003End.title, "Chapter 2")
    
    // Next chapter after Chapter 2 should be Chapter 3
    let nextChapter = toc.nextChapter(after: chapterAtTrack003End)
    XCTAssertEqual(nextChapter?.title, "Chapter 3")
    
    // Verify track change
    XCTAssertNotEqual(chapter2.position.track.key, chapter3.position.track.key,
                      "Chapter 2 and Chapter 3 should be on different tracks")
  }
  
  // MARK: - Track Index Consistency Tests
  
  /// Verifies track indices match array positions for all manifests.
  func testTrackIndexConsistency_AllManifests() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      for (arrayIndex, track) in tracks.tracks.enumerated() {
        XCTAssertEqual(track.index, arrayIndex,
                       "Track index mismatch in \(manifestJSON.rawValue): track.index=\(track.index), arrayIndex=\(arrayIndex)")
      }
    }
  }
  
  /// Tests that nextTrack uses array position, not track.index property.
  func testNextTrack_UsesArrayPosition() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    
    // Navigate through all tracks
    var currentTrack: (any Track)? = tracks.tracks.first
    var expectedIndex = 0
    
    while let track = currentTrack {
      XCTAssertEqual(track.index, expectedIndex, "Track index should match expected")
      
      let next = tracks.nextTrack(track)
      if expectedIndex < tracks.tracks.count - 1 {
        XCTAssertNotNil(next, "Should have next track at index \(expectedIndex)")
        XCTAssertEqual(next?.index, expectedIndex + 1, "Next track index should be \(expectedIndex + 1)")
      } else {
        XCTAssertNil(next, "Should not have next track at last index")
      }
      
      currentTrack = next
      expectedIndex += 1
    }
    
    XCTAssertEqual(expectedIndex, tracks.tracks.count, "Should have visited all tracks")
  }
  
  // MARK: - Chapter Navigation Complete Path Tests
  
  /// Tests navigating through all chapters in sequence.
  func testChapterNavigation_FullSequence() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    var currentChapter = toc.toc.first
    var visitedChapters: [String] = []
    
    while let chapter = currentChapter {
      visitedChapters.append(chapter.title)
      currentChapter = toc.nextChapter(after: chapter)
    }
    
    let expectedChapters = ["Opening Credits", "Chapter 1", "Part I", "Chapter 2", "Chapter 3", "Chapter 4", "Chapter 5"]
    XCTAssertEqual(visitedChapters, expectedChapters, "Should visit all chapters in order")
  }
  
  /// Tests navigating backwards through all chapters.
  func testChapterNavigation_ReverseSequence() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    var currentChapter = toc.toc.last
    var visitedChapters: [String] = []
    
    while let chapter = currentChapter {
      visitedChapters.append(chapter.title)
      currentChapter = toc.previousChapter(before: chapter)
    }
    
    let expectedChapters = ["Chapter 5", "Chapter 4", "Chapter 3", "Chapter 2", "Part I", "Chapter 1", "Opening Credits"]
    XCTAssertEqual(visitedChapters, expectedChapters, "Should visit all chapters in reverse order")
  }
  
  // MARK: - Edge Case: Empty or Single Track
  
  /// Tests behavior with manifest that has minimal tracks.
  func testMinimalManifest_SingleChapter() throws {
    // Dracula has just 2 chapters - test edge behavior
    let manifest = try loadManifest(for: .dracula)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    XCTAssertEqual(toc.toc.count, 2, "Dracula should have 2 chapters")
    
    // First chapter has no previous
    let firstChapter = toc.toc.first!
    XCTAssertNil(toc.previousChapter(before: firstChapter))
    XCTAssertNotNil(toc.nextChapter(after: firstChapter))
    
    // Last chapter has no next
    let lastChapter = toc.toc.last!
    XCTAssertNotNil(toc.previousChapter(before: lastChapter))
    XCTAssertNil(toc.nextChapter(after: lastChapter))
  }
  
  // MARK: - Edge Case: Position Near Zero
  
  /// Tests positions very close to track start.
  func testPositionNearZero() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    guard let firstTrack = tracks.tracks.first else {
      XCTFail("No tracks")
      return
    }
    
    // Test very small timestamps
    let smallTimestamps: [Double] = [0.0, 0.001, 0.01, 0.1, 0.5]
    for timestamp in smallTimestamps {
      let position = TrackPosition(track: firstTrack, timestamp: timestamp, tracks: tracks)
      XCTAssertNoThrow(try toc.chapter(forPosition: position),
                       "Should find chapter at timestamp \(timestamp)")
    }
  }
  
  // MARK: - Edge Case: Position Near Track Duration
  
  /// Tests positions very close to track end.
  func testPositionNearTrackDuration() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    for track in tracks.tracks {
      let duration = track.duration
      
      // Test positions near the end
      let nearEndTimestamps: [Double] = [
        duration - 0.5,
        duration - 0.1,
        duration - 0.01,
        duration,
        duration + 0.01  // Slightly past (should still work due to tolerance)
      ]
      
      for timestamp in nearEndTimestamps {
        let position = TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
        XCTAssertNoThrow(try toc.chapter(forPosition: position),
                         "Should find chapter at timestamp \(timestamp) on track \(track.index)")
      }
    }
  }
  
  // MARK: - Stress Test: Rapid Position Updates
  
  /// Simulates rapid position updates like during playback.
  func testRapidPositionUpdates() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Simulate 1000 position updates across the book
    for track in tracks.tracks {
      let step = track.duration / 100.0
      var timestamp = 0.0
      
      while timestamp <= track.duration {
        let position = TrackPosition(track: track, timestamp: timestamp, tracks: tracks)
        
        // Should never fail
        XCTAssertNoThrow(try toc.chapter(forPosition: position))
        
        timestamp += step
      }
    }
  }
  
  // MARK: - Helper Methods
  
  private func loadManifest(for manifestJSON: ManifestJSON) throws -> Manifest {
    try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
  }
}
