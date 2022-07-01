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
        {"time":100000,"audiobookID":"urn:uuid:b309844e-7d4e-403e-945b-fbc78acd5e03","part":0,"title":"Chapter: 3","duration":1016000,"chapter":2,"@type":"LocatorAudioBookTime"}
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
}
