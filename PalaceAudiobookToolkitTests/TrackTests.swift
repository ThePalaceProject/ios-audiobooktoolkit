//
//  TrackTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/18/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class TrackTests: XCTestCase {
    func testTrackEquality() {
        let track1 = Track(href: "http://example.com/track1.mp3", title: "Track 1", duration: 300, index: 1)
        let track2 = Track(href: "http://example.com/track1.mp3", title: "Track 1", duration: 300, index: 1)
        
        XCTAssertEqual(track1, track2, "Tracks with the same href, title, duration, and index should be equal")
    }
    
    func testTrackInequalityByIndex() {
        let track1 = Track(href: "http://example.com/track1.mp3", title: "Track 1", duration: 300, index: 1)
        let track2 = Track(href: "http://example.com/track2.mp3", title: "Track 2", duration: 200, index: 2)
        
        XCTAssertNotEqual(track1, track2, "Tracks with different indices should not be equal")
    }
    
    func testTrackOrdering() {
        let track1 = Track(href: "http://example.com/track1.mp3", title: "Track 1", duration: 300, index: 1)
        let track2 = Track(href: "http://example.com/track2.mp3", title: "Track 2", duration: 200, index: 2)
        
        XCTAssertTrue(track1 < track2, "Track 1 should come before Track 2 based on href comparison")
        XCTAssertTrue(track2 > track1, "Track 2 should come after Track 1 based on href comparison")
    }
}
