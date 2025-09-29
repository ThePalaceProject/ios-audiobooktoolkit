//
//  UnifiedPositionSystemTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Palace Team on 2024-09-21.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

// MARK: - UnifiedPositionSystemTests

/// TDD test suite defining world-class audiobook position behavior
/// Tests drive the implementation of unified position calculations
final class UnifiedPositionSystemTests: XCTestCase {
  var positionCalculator: PositionCalculating!
  var testTracks: [any Track]!
  var testTableOfContents: AudiobookTableOfContents!

  override func setUp() {
    super.setUp()
    setupTestData()
    positionCalculator = UnifiedPositionCalculator()
  }

  override func tearDown() {
    positionCalculator = nil
    testTracks = nil
    testTableOfContents = nil
    super.tearDown()
  }

  // MARK: - TDD: Anathem-Style Complex Audiobook Tests

  func test_anathemStyleChapterSeeking_shouldStayWithinChapterBoundaries() {
    // GIVEN: Anathem-style audiobook with multiple chapters per track
    let (track1, chapters) = createAnathemStyleAudiobook()
    let epigraphChapter = chapters[1] // "Chapter 2, Epigraph"

    // WHEN: User drags slider to 75% through epigraph
    let seekPosition = positionCalculator.calculateSeekPosition(
      sliderValue: 0.75,
      within: epigraphChapter
    )

    // THEN: Position should be within epigraph boundaries
    XCTAssertGreaterThanOrEqual(seekPosition.timestamp, 2700.0, "Should be at or after epigraph start")
    XCTAssertLessThanOrEqual(seekPosition.timestamp, 2820.0, "Should be at or before epigraph end")

    // AND: Should be at 75% through the 2-minute epigraph
    let expectedTimestamp = 2700.0 + (0.75 * 120.0) // 2790s
    XCTAssertEqual(seekPosition.timestamp, expectedTimestamp, accuracy: 0.1)
  }

  func test_chapterOffsetCalculation_shouldBeRelativeToChapterStart() {
    // GIVEN: Position 50 seconds into an epigraph that starts at 2700s
    let (track1, chapters) = createAnathemStyleAudiobook()
    let epigraphChapter = chapters[1]
    let positionInEpigraph = TrackPosition(track: track1, timestamp: 2750.0, tracks: testTableOfContents.tracks)

    // WHEN: Calculating chapter offset
    let offset = positionCalculator.chapterOffset(from: positionInEpigraph, chapter: epigraphChapter)

    // THEN: Offset should be relative to chapter start, not track start
    XCTAssertEqual(offset, 50.0, accuracy: 0.1, "Offset should be 50s from epigraph start")
  }

  func test_boundaryValidation_shouldClampToChapterLimits() {
    // GIVEN: Epigraph chapter with specific boundaries
    let (track1, chapters) = createAnathemStyleAudiobook()
    let epigraphChapter = chapters[1]

    // WHEN: Attempting to seek beyond chapter end
    let beyondEnd = TrackPosition(track: track1, timestamp: 3000.0, tracks: testTableOfContents.tracks)
    let validated = positionCalculator.validatePosition(beyondEnd, within: epigraphChapter)

    // THEN: Should clamp to chapter end
    XCTAssertEqual(validated.timestamp, 2820.0, accuracy: 0.1, "Should clamp to epigraph end")
  }

  func test_crossTrackChapterCalculation_shouldHandleSpanningChapters() {
    // GIVEN: Chapter spanning multiple tracks
    let (tracks, spanningChapter) = createCrossTrackChapter()
    let positionInSecondTrack = TrackPosition(track: tracks[1], timestamp: 300.0, tracks: testTableOfContents.tracks)

    // WHEN: Calculating offset for position in second track
    let offset = positionCalculator.chapterOffset(from: positionInSecondTrack, chapter: spanningChapter)

    // THEN: Should calculate total offset from chapter start
    // 900s remaining in first track + 300s into second track = 1200s
    XCTAssertEqual(offset, 1200.0, accuracy: 0.1, "Cross-track offset calculation")
  }

  // MARK: - TDD: Player Behavior Tests

  func test_modernPlayerSeek_shouldUseUnifiedCalculations() {
    // This test will drive the implementation of the modern player interface
    let player = createTestPlayer()
    let (_, chapters) = createAnathemStyleAudiobook()
    let epigraphChapter = chapters[1]

    // Set current chapter
    player.setCurrentChapter(epigraphChapter)

    // WHEN: Seeking with slider
    let expectation = XCTestExpectation(description: "Seek completion")
    player.seekWithSlider(value: 0.5) { result in
      switch result {
      case let .success(position):
        // THEN: Should use unified position calculations
        XCTAssertEqual(position.timestamp, 2760.0, accuracy: 0.1, "50% through epigraph")
        expectation.fulfill()
      case let .failure(error):
        XCTFail("Seek should succeed: \(error)")
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func test_reactiveStateManagement_shouldUpdateConsistently() {
    // This test drives reactive state implementation
    let stateManager = createTestStateManager()
    let (track1, chapters) = createAnathemStyleAudiobook()

    var receivedUpdates: [PlayerStateUpdate] = []
    let expectation = XCTestExpectation(description: "State updates")

    stateManager.statePublisher
      .sink { update in
        receivedUpdates.append(update)
        if receivedUpdates.count >= 3 {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)

    // WHEN: Position changes
    let position1 = TrackPosition(track: track1, timestamp: 2750.0, tracks: testTableOfContents.tracks)
    stateManager.updatePosition(position1)

    let position2 = TrackPosition(track: track1, timestamp: 2850.0, tracks: testTableOfContents.tracks) // Next chapter
    stateManager.updatePosition(position2)

    wait(for: [expectation], timeout: 1.0)

    // THEN: Should receive consistent state updates
    XCTAssertGreaterThanOrEqual(receivedUpdates.count, 2, "Should receive position and chapter updates")
  }

  // MARK: - Performance Tests

  func test_positionCalculationPerformance_shouldBeFast() {
    let (track1, chapters) = createAnathemStyleAudiobook()
    let chapter = chapters[1]
    let position = TrackPosition(track: track1, timestamp: 2750.0, tracks: testTableOfContents.tracks)

    measure {
      for _ in 0..<1000 {
        _ = positionCalculator.chapterOffset(from: position, chapter: chapter)
      }
    }
  }

  func test_seekingPerformance_shouldBeInstantaneous() {
    let player = createTestPlayer()
    let (_, chapters) = createAnathemStyleAudiobook()
    player.setCurrentChapter(chapters[1])

    measure {
      for i in 0..<100 {
        let value = Double(i) / 100.0
        player.seekWithSlider(value: value) { _ in }
      }
    }
  }

  // MARK: - Helper Methods

  private func setupTestData() {
    testTracks = createTestTracks()
    testTableOfContents = createTestTableOfContents()
  }

  private func createAnathemStyleAudiobook() -> (any Track, [Chapter]) {
    let track1 = MockTrack(key: "track1", duration: 5400, title: "Track 1", index: 0) // 90 minutes

    let chapter1 = Chapter(
      title: "Chapter 1",
      position: TrackPosition(track: track1, timestamp: 0, tracks: testTableOfContents.tracks),
      duration: 2700 // 45 minutes
    )

    let epigraphChapter = Chapter(
      title: "Chapter 2, Epigraph",
      position: TrackPosition(track: track1, timestamp: 2700, tracks: testTableOfContents.tracks),
      duration: 120 // 2 minutes
    )

    let chapter2 = Chapter(
      title: "Chapter 2",
      position: TrackPosition(track: track1, timestamp: 2820, tracks: testTableOfContents.tracks),
      duration: 2580 // Remaining time
    )

    return (track1, [chapter1, epigraphChapter, chapter2])
  }

  private func createCrossTrackChapter() -> ([any Track], Chapter) {
    let track1 = MockTrack(key: "track1", duration: 1800, index: 0)
    let track2 = MockTrack(key: "track2", duration: 1200, index: 1)

    // Chapter starts 900s into track1, spans to track2
    let spanningChapter = Chapter(
      title: "Cross-Track Chapter",
      position: TrackPosition(track: track1, timestamp: 900, tracks: testTableOfContents.tracks),
      duration: 1800 // 30 minutes total
    )

    return ([track1, track2], spanningChapter)
  }

  private func createTestTracks() -> [any Track] {
    [
      MockTrack(key: "track1", duration: 5400, index: 0),
      MockTrack(key: "track2", duration: 3600, index: 1)
    ]
  }

  private func createTestTableOfContents() -> AudiobookTableOfContents {
    let manifest = MockManifest()
    let tracks = MockTracks(tracks: testTracks)
    return AudiobookTableOfContents(manifest: manifest, tracks: tracks)
  }

  private func createTestPlayer() -> TestablePlayer {
    TestablePlayer(tableOfContents: testTableOfContents)
  }

  private func createTestStateManager() -> ReactivePlayerStateManager {
    ReactivePlayerStateManager(tableOfContents: testTableOfContents)
  }

  private var cancellables = Set<AnyCancellable>()
}

// MARK: - PositionCalculating

protocol PositionCalculating {
  func chapterOffset(from position: TrackPosition, chapter: Chapter) -> TimeInterval
  func chapterProgress(from position: TrackPosition, chapter: Chapter) -> Double
  func validatePosition(_ position: TrackPosition, within chapter: Chapter) -> TrackPosition
  func calculateSeekPosition(sliderValue: Double, within chapter: Chapter) -> TrackPosition
}

// MARK: - UnifiedPositionCalculator

class UnifiedPositionCalculator: PositionCalculating {
  func chapterOffset(from position: TrackPosition, chapter: Chapter) -> TimeInterval {
    do {
      return try position - chapter.position
    } catch {
      return 0.0
    }
  }

  func chapterProgress(from position: TrackPosition, chapter: Chapter) -> Double {
    let duration = chapter.duration ?? chapter.position.track.duration
    guard duration > 0 else {
      return 0.0
    }
    return chapterOffset(from: position, chapter: chapter) / duration
  }

  func validatePosition(_ position: TrackPosition, within chapter: Chapter) -> TrackPosition {
    let chapterStart = chapter.position.timestamp
    let chapterDuration = chapter.duration ?? chapter.position.track.duration
    let chapterEnd = chapterStart + chapterDuration

    let clampedTimestamp = max(chapterStart, min(position.timestamp, chapterEnd))

    return TrackPosition(
      track: chapter.position.track,
      timestamp: clampedTimestamp,
      tracks: position.tracks
    )
  }

  func calculateSeekPosition(sliderValue: Double, within chapter: Chapter) -> TrackPosition {
    let chapterDuration = chapter.duration ?? chapter.position.track.duration
    let offset = sliderValue * chapterDuration
    let absoluteTimestamp = chapter.position.timestamp + offset

    let proposedPosition = TrackPosition(
      track: chapter.position.track,
      timestamp: absoluteTimestamp,
      tracks: chapter.position.tracks
    )

    return validatePosition(proposedPosition, within: chapter)
  }
}

// MARK: - PlayerStateUpdate

enum PlayerStateUpdate {
  case positionChanged(TrackPosition)
  case chapterChanged(Chapter)
  case playbackStateChanged(PlaybackState)
}

// MARK: - ReactivePlayerStateManager

class ReactivePlayerStateManager {
  let statePublisher = PassthroughSubject<PlayerStateUpdate, Never>()
  private let tableOfContents: AudiobookTableOfContents
  private var currentPosition: TrackPosition?
  private var currentChapter: Chapter?

  init(tableOfContents: AudiobookTableOfContents) {
    self.tableOfContents = tableOfContents
  }

  func updatePosition(_ position: TrackPosition) {
    currentPosition = position
    statePublisher.send(.positionChanged(position))

    // Check for chapter change
    if let chapter = try? tableOfContents.chapter(forPosition: position),
       chapter.id != currentChapter?.id
    {
      currentChapter = chapter
      statePublisher.send(.chapterChanged(chapter))
    }
  }
}

// MARK: - TestablePlayer

protocol TestablePlayer {
  func setCurrentChapter(_ chapter: Chapter)
  func seekWithSlider(value: Double, completion: @escaping (Result<TrackPosition, Error>) -> Void)
}

// MARK: - TestablePlayer

class TestablePlayer: TestablePlayer {
  private let tableOfContents: AudiobookTableOfContents
  private let positionCalculator: PositionCalculating
  private var currentChapter: Chapter?

  init(tableOfContents: AudiobookTableOfContents) {
    self.tableOfContents = tableOfContents
    positionCalculator = UnifiedPositionCalculator()
  }

  func setCurrentChapter(_ chapter: Chapter) {
    currentChapter = chapter
  }

  func seekWithSlider(value: Double, completion: @escaping (Result<TrackPosition, Error>) -> Void) {
    guard let chapter = currentChapter else {
      completion(.failure(TestPlayerError.noCurrentChapter))
      return
    }

    let targetPosition = positionCalculator.calculateSeekPosition(sliderValue: value, within: chapter)
    completion(.success(targetPosition))
  }
}

// MARK: - TestPlayerError

enum TestPlayerError: Error {
  case noCurrentChapter
}

// MARK: - MockTrack

class MockTrack: Track {
  let key: String
  let duration: TimeInterval
  let title: String?
  let urls: [URL]?
  let index: Int
  let id: AnyHashable

  init(key: String, duration: TimeInterval, title: String? = nil, index: Int = 0) {
    self.key = key
    self.duration = duration
    self.title = title
    urls = [URL(string: "https://example.com/\(key).mp3")!]
    self.index = index
    id = key
  }

  var description: String { title ?? key }
}

// MARK: - MockManifest

class MockManifest: Manifest {
  override var audiobookType: AudiobookType { .openAccess }
}

// MARK: - MockTracks

class MockTracks: Tracks {
  private let mockTracks: [any Track]

  init(tracks: [any Track]) {
    mockTracks = tracks
    super.init(manifest: MockManifest(), audiobookID: "test", token: nil)
  }

  override var tracks: [any Track] { mockTracks }
  override var totalDuration: Double { mockTracks.reduce(0) { $0 + $1.duration } }

  override func track(forKey key: String) -> (any Track)? {
    mockTracks.first { $0.key == key }
  }
}
