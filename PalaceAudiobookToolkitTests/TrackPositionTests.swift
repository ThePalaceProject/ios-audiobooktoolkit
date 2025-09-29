//
//  TrackPositionTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/18/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class TrackPositionTests: XCTestCase {
  let testID = "TestID"
  func testTrackPositionAcrossAllManifests() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try loadManifest(for: manifestJSON)
        let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)

        try testAdditionAndSubtractionForAllTracks(tracks)
      } catch {
        XCTFail("Error for \(manifestJSON.rawValue): \(error)")
      }
    }
  }

  private func loadManifest(for manifestJSON: ManifestJSON) throws -> Manifest {
    try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
  }

  private func testAdditionAndSubtractionForAllTracks(_ tracks: Tracks) throws {
    guard !tracks.tracks.isEmpty else {
      print("No tracks available for testing.")
      return
    }

    for (index, track) in tracks.tracks.enumerated() {
      let startPosition = TrackPosition(track: track, timestamp: 0, tracks: tracks)
      let middlePosition = TrackPosition(track: track, timestamp: track.duration / 2, tracks: tracks)

      try testTimeAdditionWithinTrack(middlePosition)
      try testTimeSubtractionWithinTrack(middlePosition)

      // Safely attempt to navigate to the next track
      if index + 1 < tracks.tracks.count - 1 {
        let nextTrackStartPosition = TrackPosition(track: tracks.tracks[index + 1], timestamp: 0, tracks: tracks)
        try testMovingToNextTrack(from: startPosition, in: nextTrackStartPosition.tracks)
      } else {
        print("Reached the end of the track list at index \(index); cannot move to a next track.")
      }

      // Safely attempt to navigate to the previous track
      if index > 1 {
        let previousTrackStartPosition = TrackPosition(track: tracks.tracks[index - 1], timestamp: 0, tracks: tracks)
        try testMovingToPreviousTrack(from: startPosition, in: previousTrackStartPosition.tracks)
      } else {
        print("At the start of the track list at index \(index); cannot move to a previous track.")
      }
    }
  }

  private func testTimeAdditionWithinTrack(_ position: TrackPosition) throws {
    let newPosition = position + (position.track.duration / 2)
    XCTAssertLessThanOrEqual(
      newPosition.timestamp,
      position.track.duration,
      "Addition should stay within the same track."
    )
  }

  private func testTimeSubtractionWithinTrack(_ position: TrackPosition) throws {
    let newPosition = position + (position.track.duration / 2)
    XCTAssertGreaterThanOrEqual(newPosition.timestamp, 0, "Subtraction should not result in a negative timestamp.")
  }

  private func testMovingToNextTrack(from position: TrackPosition, in _: Tracks) throws {
    let newPosition = position + (position.track.duration - position.timestamp + 10)
    XCTAssertNotEqual(newPosition.track.id, position.track.id, "Should move to the next track.")
  }

  private func testMovingToPreviousTrack(from position: TrackPosition, in _: Tracks) throws {
    let newPosition = position + (-1 * (position.timestamp + 10))
    XCTAssertNotEqual(newPosition.track.id, position.track.id, "Should move to the previous track.")
  }
}
