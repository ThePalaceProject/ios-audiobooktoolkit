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
                let tracks = Tracks(manifest: manifest, audiobookID: testID)
                
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
        for (index, track) in tracks.tracks.enumerated() {
            let startPosition = TrackPosition(track: track, timestamp: 0, tracks: tracks)
            let middlePosition = TrackPosition(track: track, timestamp: track.duration / 2, tracks: tracks)
            
            try testTimeAdditionWithinTrack(middlePosition)
            try testTimeSubtractionWithinTrack(middlePosition)
            
            if index < tracks.tracks.count - 1 {
                try testMovingToNextTrack(from: startPosition, in: tracks)
            }
            if index > 0 {
                try testMovingToPreviousTrack(from: startPosition, in: tracks)
            }
        }
    }
    
    private func testTimeAdditionWithinTrack(_ position: TrackPosition) throws {
        let newPosition = try position + 1000
        XCTAssertLessThan(newPosition.timestamp, position.track.duration, "Addition should stay within the same track.")
    }
    
    private func testTimeSubtractionWithinTrack(_ position: TrackPosition) throws {
        let newPosition = try position + (-1000)
        XCTAssertGreaterThanOrEqual(newPosition.timestamp, 0, "Subtraction should not result in a negative timestamp.")
    }
    
    private func testMovingToNextTrack(from position: TrackPosition, in tracks: Tracks) throws {
        let newPosition = try position + (position.track.duration - position.timestamp + 1000)
        XCTAssertNotEqual(newPosition.track.id, position.track.id, "Should move to the next track.")
    }
    
    private func testMovingToPreviousTrack(from position: TrackPosition, in tracks: Tracks) throws {
        let newPosition = try position + (-1 * (position.timestamp + 1))
        XCTAssertNotEqual(newPosition.track.id, position.track.id, "Should move to the previous track.")
    }
}
