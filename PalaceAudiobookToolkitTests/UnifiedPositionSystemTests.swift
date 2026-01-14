//
//  UnifiedPositionSystemTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Palace Team on 2024-09-21.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

// MARK: - UnifiedPositionCalculatorTests

/// Tests for the UnifiedPositionCalculator - the single source of truth for audiobook position math
final class UnifiedPositionCalculatorTests: XCTestCase {
  private let testID = "testID"
  private var calculator: UnifiedPositionCalculator!

  override func setUp() {
    super.setUp()
    calculator = UnifiedPositionCalculator()
  }

  override func tearDown() {
    calculator = nil
    super.tearDown()
  }

  // MARK: - chapterOffset Tests
  
  func testChapterOffset_PositionAtChapterStart_ReturnsZero() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    // Position exactly at chapter start
    let position = firstChapter.position
    let offset = calculator.chapterOffset(from: position, chapter: firstChapter)
    
    XCTAssertEqual(offset, 0.0, accuracy: 0.1, "Offset at chapter start should be 0")
  }
  
  func testChapterOffset_PositionMidChapter_ReturnsCorrectOffset() throws {
    let (toc, tracks) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    // Position 30 seconds into chapter
    let position = TrackPosition(
      track: firstChapter.position.track,
      timestamp: firstChapter.position.timestamp + 30.0,
      tracks: tracks
    )
    let offset = calculator.chapterOffset(from: position, chapter: firstChapter)
    
    XCTAssertEqual(offset, 30.0, accuracy: 0.1, "Offset should be 30 seconds")
  }
  
  // MARK: - chapterProgress Tests
  
  func testChapterProgress_AtStart_ReturnsZero() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let position = firstChapter.position
    let progress = calculator.chapterProgress(from: position, chapter: firstChapter)
    
    XCTAssertEqual(progress, 0.0, accuracy: 0.01, "Progress at chapter start should be 0")
  }
  
  func testChapterProgress_AtMidpoint_ReturnsFiftyPercent() throws {
    let (toc, tracks) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let chapterDuration = firstChapter.duration ?? firstChapter.position.track.duration
    let midpoint = firstChapter.position.timestamp + (chapterDuration / 2.0)
    
    let position = TrackPosition(
      track: firstChapter.position.track,
      timestamp: midpoint,
      tracks: tracks
    )
    let progress = calculator.chapterProgress(from: position, chapter: firstChapter)
    
    XCTAssertEqual(progress, 0.5, accuracy: 0.1, "Progress at chapter midpoint should be ~50%")
  }
  
  // MARK: - totalBookProgress Tests
  
  func testTotalBookProgress_AtStart_ReturnsZero() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let position = firstChapter.position
    let progress = calculator.totalBookProgress(from: position, tableOfContents: toc)
    
    XCTAssertEqual(progress, 0.0, accuracy: 0.01, "Progress at book start should be ~0%")
  }
  
  // MARK: - validatePosition Tests
  
  func testValidatePosition_AtChapterStart_ReturnsStart() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let position = firstChapter.position
    let validated = calculator.validatePosition(position, within: firstChapter)
    
    XCTAssertEqual(validated.timestamp, firstChapter.position.timestamp, accuracy: 0.1,
                   "Position at chapter start should be unchanged")
  }
  
  func testValidatePosition_NegativeTimestamp_ClampsToStart() throws {
    let (toc, tracks) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let chapterStart = firstChapter.position.timestamp
    
    // Position with negative timestamp
    let position = TrackPosition(
      track: firstChapter.position.track,
      timestamp: -10.0,
      tracks: tracks
    )
    
    let validated = calculator.validatePosition(position, within: firstChapter)
    
    XCTAssertGreaterThanOrEqual(validated.timestamp, chapterStart,
                   "Negative timestamp should be clamped to chapter start")
  }
  
  // MARK: - calculateSeekPosition Tests
  
  func testCalculateSeekPosition_AtZero_ReturnsChapterStart() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let seekPosition = calculator.calculateSeekPosition(sliderValue: 0.0, within: firstChapter)
    
    XCTAssertEqual(seekPosition.timestamp, firstChapter.position.timestamp, accuracy: 0.1,
                   "Seek at 0% should return chapter start")
  }
  
  func testCalculateSeekPosition_AtHalf_ReturnsChapterMidpoint() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let chapterDuration = firstChapter.duration ?? firstChapter.position.track.duration
    let expectedMidpoint = firstChapter.position.timestamp + (chapterDuration / 2.0)
    
    let seekPosition = calculator.calculateSeekPosition(sliderValue: 0.5, within: firstChapter)
    
    XCTAssertEqual(seekPosition.timestamp, expectedMidpoint, accuracy: 1.0,
                   "Seek at 50% should return chapter midpoint")
  }
  
  // MARK: - Helper Methods
  
  private func loadTableOfContents(for json: ManifestJSON) throws -> (AudiobookTableOfContents, Tracks) {
    let manifest = try Manifest.from(jsonFileName: json.rawValue, bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    return (toc, tracks)
  }
}

// MARK: - ReactivePlayerStateManagerTests

@MainActor
final class ReactivePlayerStateManagerTests: XCTestCase {
  private let testID = "testID"
  
  func testStateManagerInitialization() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    let stateManager = ReactivePlayerStateManager(tableOfContents: toc)
    
    XCTAssertNil(stateManager.currentPosition)
    XCTAssertNil(stateManager.currentChapter)
    XCTAssertFalse(stateManager.isPlaying)
    XCTAssertFalse(stateManager.isLoaded)
    XCTAssertEqual(stateManager.chapterProgress, 0.0)
    XCTAssertEqual(stateManager.totalProgress, 0.0)
  }
  
  func testUpdatePosition_SetsCurrentPosition() throws {
    let (toc, tracks) = try loadTableOfContents(for: .alice)
    let stateManager = ReactivePlayerStateManager(tableOfContents: toc)
    
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    let position = TrackPosition(
      track: firstChapter.position.track,
      timestamp: 10.0,
      tracks: tracks
    )
    
    stateManager.updatePosition(position)
    
    XCTAssertNotNil(stateManager.currentPosition)
    XCTAssertEqual(stateManager.currentPosition!.timestamp, 10.0, accuracy: 0.1)
  }
  
  func testUpdatePlaybackState_SetsIsPlaying() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    let stateManager = ReactivePlayerStateManager(tableOfContents: toc)
    
    XCTAssertFalse(stateManager.isPlaying)
    
    stateManager.updatePlaybackState(true)
    XCTAssertTrue(stateManager.isPlaying)
    
    stateManager.updatePlaybackState(false)
    XCTAssertFalse(stateManager.isPlaying)
  }
  
  func testUpdateLoadedState_SetsIsLoaded() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    let stateManager = ReactivePlayerStateManager(tableOfContents: toc)
    
    XCTAssertFalse(stateManager.isLoaded)
    
    stateManager.updateLoadedState(true)
    XCTAssertTrue(stateManager.isLoaded)
    
    stateManager.updateLoadedState(false)
    XCTAssertFalse(stateManager.isLoaded)
  }
  
  func testRequestSeek_WithoutChapter_ReturnsNil() throws {
    let (toc, _) = try loadTableOfContents(for: .alice)
    let stateManager = ReactivePlayerStateManager(tableOfContents: toc)
    
    // No current chapter set, seek should fail
    let result = stateManager.requestSeek(sliderValue: 0.5)
    XCTAssertNil(result, "Seek without current chapter should return nil")
  }
  
  func testRequestSeek_WithChapter_ReturnsPosition() throws {
    let (toc, tracks) = try loadTableOfContents(for: .alice)
    let stateManager = ReactivePlayerStateManager(tableOfContents: toc)
    
    guard let firstChapter = toc.toc.first else {
      XCTFail("No chapters found")
      return
    }
    
    // Set initial position to establish current chapter
    stateManager.updatePosition(firstChapter.position)
    
    let result = stateManager.requestSeek(sliderValue: 0.5)
    XCTAssertNotNil(result, "Seek with current chapter should return position")
  }
  
  // MARK: - Helper Methods
  
  private func loadTableOfContents(for json: ManifestJSON) throws -> (AudiobookTableOfContents, Tracks) {
    let manifest = try Manifest.from(jsonFileName: json.rawValue, bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    return (toc, tracks)
  }
}
