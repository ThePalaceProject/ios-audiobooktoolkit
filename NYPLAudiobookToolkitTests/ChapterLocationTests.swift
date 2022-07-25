//
//  ChapterLocationTests.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Maurice Work on 6/30/22.
//  Copyright © 2022 Dean Silfen. All rights reserved.
//

import XCTest
@testable import NYPLAudiobookToolkit

class ChapterLocationTests: XCTestCase {
    let testJSON = """
        {
            "time":100000,
            "audiobookID":"urn:uuid:b309844e-7d4e-403e-945b-fbc78acd5e03",
            "part":0,
            "title":"Chapter: 3",
            "duration":1016000,
            "chapter":2,
            "@type":"LocatorAudioBookTime"
        }
    """
    
    let legacyTestJSON = """
        {
            "number":1,
            "playheadOffset":13.408212976,
            "audiobookID":"urn:isbn:9781603932646",
            "startOffset":0,
            "title":"Opening Credits",
            "part":0,
            "duration":18
        }
    """
    func testDecoder() {
        let data = testJSON.data(using: .utf8)!
        let location = ChapterLocation.fromData(data)
        XCTAssertEqual(location?.playheadOffset, Double(100))
        XCTAssertEqual(location?.audiobookID, "urn:uuid:b309844e-7d4e-403e-945b-fbc78acd5e03")
        XCTAssertEqual(location?.part, 0)
        XCTAssertEqual(location?.duration, Double(1016))
        XCTAssertEqual(location?.title, "Chapter: 3")
        XCTAssertEqual(location?.number, 2)
        XCTAssertEqual(location?.type, "LocatorAudioBookTime")
    }
    
    func testDecoderLegacyData() {
        let data = legacyTestJSON.data(using: .utf8)!
        let location = ChapterLocation.fromData(data)
        XCTAssertEqual(location?.playheadOffset, Double(13.408212661743164))
        XCTAssertEqual(location?.audiobookID, "urn:isbn:9781603932646")
        XCTAssertEqual(location?.part, 0)
        XCTAssertEqual(location?.duration, Double(18))
        XCTAssertEqual(location?.title, "Opening Credits")
        XCTAssertEqual(location?.number, 1)
        XCTAssertEqual(location?.type, "LocatorAudioBookTime")
    }
}
