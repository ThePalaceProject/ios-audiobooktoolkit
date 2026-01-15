//
//  ManifestFormatTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Palace Team on 2026-01-14.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

/// Tests for different manifest formats: Findaway, Overdrive, LCP, OpenAccess
/// Ensures that chapter navigation and track handling work correctly across all formats.
final class ManifestFormatTests: XCTestCase {
  private let testID = "testID"
  
  // MARK: - Format Detection Tests
  
  /// Tests that manifest types are correctly detected based on their properties.
  func testAudiobookTypeDetection() throws {
    // LCP manifests have encrypted scheme in readingOrder
    let lcpManifest = try loadManifest(for: .dracula)
    XCTAssertEqual(lcpManifest.audiobookType, .lcp, "Dracula should be detected as LCP")
    
    let dungeonCrawler = try loadManifest(for: .dungeonCrawlerCarl)
    // If it has LCP encryption markers, it's LCP
    let isDungeonLCP = dungeonCrawler.readingOrder?.contains {
      $0.properties?.encrypted?.scheme == "http://readium.org/2014/01/lcp"
    } ?? false
    
    if isDungeonLCP {
      XCTAssertEqual(dungeonCrawler.audiobookType, .lcp)
    }
    
    // Open Access manifests have no encryption
    let openAccessManifest = try loadManifest(for: .alice)
    if openAccessManifest.readingOrder?.allSatisfy({ $0.properties?.encrypted == nil }) == true {
      XCTAssertEqual(openAccessManifest.audiobookType, .openAccess, "Alice should be OpenAccess")
    }
  }
  
  // MARK: - LCP Format Tests
  
  /// Tests LCP manifest parsing and chapter navigation.
  func testLCPFormat_ChapterNavigation() throws {
    let manifest = try loadManifest(for: .dracula)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Basic structure validation
    XCTAssertFalse(toc.toc.isEmpty, "LCP manifest should have chapters")
    XCTAssertFalse(tracks.tracks.isEmpty, "LCP manifest should have tracks")
    
    // Navigate through all chapters
    for (index, chapter) in toc.toc.enumerated() {
      // Chapter start position should be findable
      let chapterAtStart = try toc.chapter(forPosition: chapter.position)
      XCTAssertEqual(chapterAtStart.title, chapter.title,
                     "Chapter \(index) position should return that chapter")
      
      // If not the last chapter, next chapter should exist
      if index < toc.toc.count - 1 {
        let nextChapter = toc.nextChapter(after: chapter)
        XCTAssertNotNil(nextChapter, "Chapter \(index) should have a next chapter")
      }
    }
  }
  
  /// Tests LCP manifest track end behavior.
  func testLCPFormat_TrackEndPositions() throws {
    let manifest = try loadManifest(for: .dracula)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    for track in tracks.tracks {
      let endPosition = TrackPosition(track: track, timestamp: track.duration, tracks: tracks)
      
      // Should always find a chapter at track end
      XCTAssertNoThrow(try toc.chapter(forPosition: endPosition),
                       "Should find chapter at end of track \(track.index)")
    }
  }
  
  // MARK: - Open Access Format Tests
  
  /// Tests Open Access manifest parsing and chapter navigation.
  func testOpenAccessFormat_ChapterNavigation() throws {
    let manifest = try loadManifest(for: .alice)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Basic structure validation
    XCTAssertFalse(toc.toc.isEmpty, "OpenAccess manifest should have chapters")
    XCTAssertFalse(tracks.tracks.isEmpty, "OpenAccess manifest should have tracks")
    
    // Navigate through all chapters
    var currentChapter = toc.toc.first
    var chapterCount = 0
    
    while let chapter = currentChapter {
      chapterCount += 1
      currentChapter = toc.nextChapter(after: chapter)
    }
    
    XCTAssertEqual(chapterCount, toc.toc.count, "Should visit all chapters")
  }
  
  /// Tests Open Access manifest with many chapters (Snowcrash).
  func testOpenAccessFormat_ManyChapters() throws {
    let manifest = try loadManifest(for: .snowcrash)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Snowcrash has 72 chapters - stress test navigation
    XCTAssertEqual(toc.toc.count, 72, "Snowcrash should have 72 chapters")
    
    // Navigate forward through all
    var forwardCount = 0
    var currentChapter = toc.toc.first
    while let chapter = currentChapter {
      forwardCount += 1
      currentChapter = toc.nextChapter(after: chapter)
    }
    XCTAssertEqual(forwardCount, 72)
    
    // Navigate backward through all
    var backwardCount = 0
    currentChapter = toc.toc.last
    while let chapter = currentChapter {
      backwardCount += 1
      currentChapter = toc.previousChapter(before: chapter)
    }
    XCTAssertEqual(backwardCount, 72)
  }
  
  // MARK: - Chapter Offset Tests Across Formats
  
  /// Tests chapter offset calculation for different manifest formats.
  func testChapterOffset_AllFormats() throws {
    let manifestsToTest: [ManifestJSON] = [.alice, .snowcrash, .martian, .dungeonCrawlerCarl]
    
    for manifestJSON in manifestsToTest {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      
      // Test offset at chapter start (should be 0)
      for chapter in toc.toc {
        let offsetAtStart = try toc.chapterOffset(for: chapter.position)
        XCTAssertEqual(offsetAtStart, 0.0, accuracy: 0.5,
                       "Offset at chapter start should be ~0 for \(manifestJSON.rawValue)")
      }
      
      // Test offset at middle of first chapter
      if let firstChapter = toc.toc.first,
         let duration = firstChapter.duration, duration > 20 {
        let midPosition = TrackPosition(
          track: firstChapter.position.track,
          timestamp: firstChapter.position.timestamp + 10.0,
          tracks: tracks
        )
        let offset = try toc.chapterOffset(for: midPosition)
        XCTAssertEqual(offset, 10.0, accuracy: 0.5,
                       "Offset should be ~10 for \(manifestJSON.rawValue)")
      }
    }
  }
  
  // MARK: - Reading Order vs TOC Structure Tests
  
  /// Tests that reading order (tracks) and TOC (chapters) are properly linked.
  func testReadingOrderTOCAlignment() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      
      // Each chapter position should reference a valid track
      for chapter in toc.toc {
        let trackExists = tracks.tracks.contains { $0.key == chapter.position.track.key }
        XCTAssertTrue(trackExists,
                      "Chapter '\(chapter.title)' should reference valid track in \(manifestJSON.rawValue)")
      }
    }
  }
  
  // MARK: - Track Duration Consistency Tests
  
  /// Tests that track durations are properly set and positive.
  func testTrackDurations_AllFormats() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      
      for track in tracks.tracks {
        XCTAssertGreaterThan(track.duration, 0,
                             "Track \(track.index) duration should be positive in \(manifestJSON.rawValue)")
      }
      
      // Total duration should be sum of all tracks
      let sumOfTracks = tracks.tracks.reduce(0.0) { $0 + $1.duration }
      XCTAssertEqual(tracks.totalDuration, sumOfTracks, accuracy: 0.1,
                     "Total duration should equal sum of tracks in \(manifestJSON.rawValue)")
    }
  }
  
  // MARK: - Metadata Validation Tests
  
  /// Tests that essential metadata is present across formats.
  func testMetadata_AllFormats() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      
      // Title should exist
      XCTAssertNotNil(manifest.metadata?.title,
                      "Manifest should have title in \(manifestJSON.rawValue)")
      
      // Duration should be positive if present
      if let duration = manifest.metadata?.duration {
        XCTAssertGreaterThan(duration, 0,
                             "Metadata duration should be positive in \(manifestJSON.rawValue)")
      }
    }
  }
  
  // MARK: - Edge Cases: Very Short/Long Books
  
  /// Tests manifest with very few chapters (minimal structure).
  func testMinimalChapterCount() throws {
    let manifest = try loadManifest(for: .dracula)  // Has only 2 chapters
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    XCTAssertEqual(toc.toc.count, 2, "Dracula should have 2 chapters")
    
    // First chapter navigation
    let first = toc.toc[0]
    XCTAssertNil(toc.previousChapter(before: first))
    XCTAssertNotNil(toc.nextChapter(after: first))
    
    // Last chapter navigation
    let last = toc.toc[1]
    XCTAssertNotNil(toc.previousChapter(before: last))
    XCTAssertNil(toc.nextChapter(after: last))
  }
  
  /// Tests manifest with many chapters (complex structure).
  func testLargeChapterCount() throws {
    // Snowcrash has 72 chapters
    let manifest = try loadManifest(for: .snowcrash)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    XCTAssertEqual(toc.toc.count, 72)
    
    // Random access should work
    let randomIndices = [0, 10, 25, 50, 71]
    for index in randomIndices {
      let chapter = toc.toc[index]
      let found = try toc.chapter(forPosition: chapter.position)
      XCTAssertEqual(found.title, chapter.title, "Random access to chapter \(index) should work")
    }
  }
  
  // MARK: - Complex TOC Structure Tests
  
  /// Tests manifest with hierarchical TOC (if any have nested structure).
  func testComplexTOCStructure() throws {
    // TheSystemOfTheWorld has 47 chapters - test complex navigation
    let manifest = try loadManifest(for: .theSystemOfTheWorld)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    XCTAssertEqual(toc.toc.count, 47)
    
    // Test that all positions are in ascending order
    var previousPosition: TrackPosition?
    for chapter in toc.toc {
      if let prev = previousPosition {
        // Current position should be >= previous
        let comparison = chapter.position >= prev
        XCTAssertTrue(comparison,
                      "Chapters should be in ascending position order")
      }
      previousPosition = chapter.position
    }
  }
  
  // MARK: - Format-Specific Edge Cases
  
  /// Tests that multi-chapter-same-track scenario works (PP-3518).
  func testMultiChapterSameTrack_DetailedValidation() throws {
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Find chapters on the same track
    var trackToChapters: [String: [Chapter]] = [:]
    for chapter in toc.toc {
      let key = chapter.position.track.key
      trackToChapters[key, default: []].append(chapter)
    }
    
    // Find tracks with multiple chapters
    let multiChapterTracks = trackToChapters.filter { $0.value.count > 1 }
    
    if !multiChapterTracks.isEmpty {
      for (trackKey, chapters) in multiChapterTracks {
        // Chapters should be in timestamp order
        var previousTimestamp = -1.0
        for chapter in chapters.sorted(by: { $0.position.timestamp < $1.position.timestamp }) {
          XCTAssertGreaterThan(chapter.position.timestamp, previousTimestamp,
                               "Chapters on track \(trackKey) should have increasing timestamps")
          previousTimestamp = chapter.position.timestamp
        }
        
        // Test position identification within each chapter region
        for (index, chapter) in chapters.enumerated() {
          let nextChapterStart = index + 1 < chapters.count
            ? chapters[index + 1].position.timestamp
            : tracks.tracks.first { $0.key == trackKey }?.duration ?? chapter.position.timestamp + 1
          
          // Test position in middle of this chapter
          let midTimestamp = (chapter.position.timestamp + nextChapterStart) / 2.0
          let midPosition = TrackPosition(
            track: chapter.position.track,
            timestamp: midTimestamp,
            tracks: tracks
          )
          
          let foundChapter = try toc.chapter(forPosition: midPosition)
          XCTAssertEqual(foundChapter.title, chapter.title,
                         "Position at t=\(midTimestamp) should be in '\(chapter.title)'")
        }
      }
    }
  }
  
  // MARK: - Position Comparison Tests
  
  /// Tests TrackPosition comparison operators across formats.
  func testTrackPositionComparison() throws {
    let manifest = try loadManifest(for: .alice)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    
    guard tracks.tracks.count >= 2 else {
      XCTFail("Need at least 2 tracks")
      return
    }
    
    let track1 = tracks.tracks[0]
    let track2 = tracks.tracks[1]
    
    // Same track, different timestamps
    let pos1a = TrackPosition(track: track1, timestamp: 10.0, tracks: tracks)
    let pos1b = TrackPosition(track: track1, timestamp: 20.0, tracks: tracks)
    XCTAssertTrue(pos1a < pos1b, "Earlier timestamp should be less than later")
    XCTAssertFalse(pos1a == pos1b, "Different timestamps should not be equal")
    
    // Different tracks
    let pos2 = TrackPosition(track: track2, timestamp: 5.0, tracks: tracks)
    XCTAssertTrue(pos1b < pos2, "Position on earlier track should be less than later track")
    
    // Equal positions (within tolerance)
    let pos1c = TrackPosition(track: track1, timestamp: 10.05, tracks: tracks)
    XCTAssertTrue(pos1a == pos1c, "Positions within tolerance should be equal")
  }
  
  // MARK: - Helper Methods
  
  private func loadManifest(for manifestJSON: ManifestJSON) throws -> Manifest {
    try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
  }
}
