//
//  NowPlayingTimeTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Palace on 1/25/26.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

/// Tests for Now Playing time calculations to ensure time remaining is never negative.
/// These tests verify the fix for the CarPlay negative time remaining bug.
class NowPlayingTimeTests: XCTestCase {
  private let testID = "testID"

  // MARK: - Chapter Offset Tests

  /// Tests that chapterOffset returns a value clamped to [0, chapterDuration]
  /// **of the chapter the position actually falls in**.
  ///
  /// The original version of this test compared the offset against the FIRST
  /// chapter's duration while walking timestamps well past that chapter — up to
  /// ten times its length. Those positions are in a later chapter, and
  /// `chapterOffset` clamps to the duration of the chapter it resolves, so the
  /// comparison was against the wrong chapter and failed by construction (e.g.
  /// offset 27.0 vs. a first-chapter duration of 3.0 in Alice). The invariant
  /// worth pinning is the one Now Playing depends on: whatever chapter you land
  /// in, elapsed time within it is in `[0, that chapter's duration]`.
  func testChapterOffset_NeverExceedsDuration() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

      guard let firstChapter = toc.toc.first,
            let firstDuration = firstChapter.duration else { continue }

      let testTimestamps = [0.0, firstDuration / 2, firstDuration, firstDuration * 2, firstDuration * 10]

      for timestamp in testTimestamps {
        let position = TrackPosition(
          track: firstChapter.position.track,
          timestamp: timestamp,
          tracks: tracks
        )

        guard let offset = try? toc.chapterOffset(for: position),
              let resolved = try? toc.chapter(forPosition: position)
        else { continue }

        let resolvedDuration = resolved.duration ?? position.track.duration
        XCTAssertLessThanOrEqual(
          offset,
          resolvedDuration,
          "Offset (\(offset)) exceeds the duration (\(resolvedDuration)) of the chapter it resolved to "
            + "('\(resolved.title)') for timestamp \(timestamp) in \(manifestJSON.rawValue)"
        )
        XCTAssertGreaterThanOrEqual(
          offset,
          0,
          "Chapter offset (\(offset)) should not be negative for timestamp \(timestamp) in \(manifestJSON.rawValue)"
        )
      }
    }
  }

  /// Tests that chapterOffset returns 0 for positions before or at chapter start
  func testChapterOffset_ZeroAtStart() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      
      guard let firstChapter = toc.toc.first else { continue }
      
      // Position at the exact start of the chapter
      let startPosition = TrackPosition(
        track: firstChapter.position.track,
        timestamp: firstChapter.position.timestamp,
        tracks: tracks
      )
      
      if let offset = try? toc.chapterOffset(for: startPosition) {
        XCTAssertEqual(
          offset,
          0,
          "Chapter offset at chapter start should be 0 in \(manifestJSON.rawValue), got \(offset)"
        )
      }
    }
  }

  /// Tests that chapterOffset handles edge case where position timestamp is before chapter start
  func testChapterOffset_NeverNegative() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      
      guard let firstChapter = toc.toc.first else { continue }
      
      // Position before the chapter start (edge case)
      let beforeStart = TrackPosition(
        track: firstChapter.position.track,
        timestamp: max(0, firstChapter.position.timestamp - 10),
        tracks: tracks
      )
      
      if let offset = try? toc.chapterOffset(for: beforeStart) {
        XCTAssertGreaterThanOrEqual(
          offset,
          0,
          "Chapter offset should never be negative in \(manifestJSON.rawValue), got \(offset)"
        )
      }
    }
  }

  // MARK: - Time Remaining Calculation Tests

  /// Tests that time remaining (duration - elapsed) is never negative.
  ///
  /// This is the CarPlay invariant: the lock screen and the car display both
  /// render `duration - elapsed`, and a negative value there is visible and
  /// wrong. It has to be computed from ONE chapter — the one the position
  /// resolves to. The original version took `elapsed` from `chapterOffset` (the
  /// resolved chapter) and `duration` from the chapter being iterated, which are
  /// not the same chapter once a timestamp runs past the end of the one it
  /// started in; that produced arithmetic like `1141.0 - 1142.0` between two
  /// unrelated chapters.
  func testTimeRemaining_NeverNegative() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)

      for chapter in toc.toc {
        guard let chapterDuration = chapter.duration, chapterDuration > 0 else { continue }

        // Test at various positions
        let testTimestamps = [0.0, chapterDuration / 2, chapterDuration, chapterDuration + 100]

        for timestamp in testTimestamps {
          let position = TrackPosition(
            track: chapter.position.track,
            timestamp: timestamp,
            tracks: tracks
          )

          guard let elapsed = try? toc.chapterOffset(for: position),
                let resolved = try? toc.chapter(forPosition: position)
          else { continue }

          let resolvedDuration = resolved.duration ?? position.track.duration
          let timeRemaining = resolvedDuration - elapsed

          XCTAssertGreaterThanOrEqual(
            timeRemaining,
            0,
            "Time remaining should never be negative. Duration: \(resolvedDuration), "
              + "Elapsed: \(elapsed), Remaining: \(timeRemaining) for chapter "
              + "'\(resolved.title)' in \(manifestJSON.rawValue)"
          )
        }
      }
    }
  }

  // MARK: - Multi-Chapter Same Track Tests

  /// Tests chapter offset calculation for audiobooks with multiple chapters on the same track
  func testChapterOffset_MultiChapterSameTrack() throws {
    // Dungeon Crawler Carl has multiple chapters on the same track
    let manifest = try loadManifest(for: .dungeonCrawlerCarl)
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    
    // Part I and Chapter 2 share track 003
    guard toc.toc.count >= 4 else {
      XCTFail("Expected at least 4 chapters")
      return
    }
    
    let partI = toc.toc[2]
    let chapter2 = toc.toc[3]
    
    // Verify they share the same track
    XCTAssertEqual(partI.position.track.key, chapter2.position.track.key)
    
    // Test offset at various points
    guard let partIDuration = partI.duration,
          let chapter2Duration = chapter2.duration else {
      XCTFail("Chapters should have duration")
      return
    }
    
    // Position in the middle of Part I
    let midPartI = TrackPosition(
      track: partI.position.track,
      timestamp: partI.position.timestamp + partIDuration / 2,
      tracks: tracks
    )
    
    if let offset = try? toc.chapterOffset(for: midPartI) {
      XCTAssertLessThanOrEqual(offset, partIDuration, "Offset should not exceed Part I duration")
      XCTAssertGreaterThanOrEqual(offset, 0, "Offset should not be negative")
    }
    
    // Position at the end of the track (should be in Chapter 2)
    let trackEnd = TrackPosition(
      track: chapter2.position.track,
      timestamp: chapter2.position.track.duration,
      tracks: tracks
    )
    
    if let offset = try? toc.chapterOffset(for: trackEnd) {
      // When at end of track, we should be in Chapter 2
      XCTAssertLessThanOrEqual(offset, chapter2Duration, "Offset at track end should not exceed Chapter 2 duration")
      XCTAssertGreaterThanOrEqual(offset, 0, "Offset should not be negative")
    }
  }

  // MARK: - Duration Validity Tests

  /// Tests that all chapters have valid durations
  func testChapterDurations_ArePositive() throws {
    for manifestJSON in ManifestJSON.allCases {
      let manifest = try loadManifest(for: manifestJSON)
      let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
      let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
      
      for (index, chapter) in toc.toc.enumerated() {
        if let duration = chapter.duration {
          XCTAssertGreaterThan(
            duration,
            0,
            "Chapter[\(index)] '\(chapter.title)' should have positive duration in \(manifestJSON.rawValue), got \(duration)"
          )
        }
      }
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
