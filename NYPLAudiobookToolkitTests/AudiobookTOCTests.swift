//
//  AudiobookTOCTests.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Maurice Work on 4/5/22.
//  Copyright © 2022 Dean Silfen. All rights reserved.
//

import XCTest
@testable import NYPLAudiobookToolkit

class AudiobookTOCTests: XCTestCase {

    struct TestOutcome {
        var chapter: UInt
        var offset: Double
        var duration: Double
        var mediaType: LCPSpineElementMediaType
    }

    var tocManaifestExpectedResults = [
        TestOutcome(chapter: UInt(1), offset: 71.0, duration: 9.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 80.0, duration: 335.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 415.0, duration: 374.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 789.0, duration: 582.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 18.0, duration: 864.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 882.0, duration: 787.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 17.0, duration: 931.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 948.0, duration: 558.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 17.0, duration: 448.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 465.0, duration: 659.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 1124.0, duration: 674.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 17.0, duration: 435.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 452.0, duration: 773.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 17.0, duration: 8.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 25.0, duration: 777.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 802.0, duration: 857.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 564.0, duration: 0.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 564.0, duration: 1164.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 1728.0, duration: 358.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 16.0, duration: 965.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 981.0, duration: 1117.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 2098.0, duration: 564.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 18.0, duration: 437.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 455.0, duration: 722.0, mediaType: .audioMPEG)
    ]

    var nonTocManifestExpeectedResults = [
        TestOutcome(chapter: UInt(1), offset: 0.0, duration: 487.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 0.0, duration: 437.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 0.0, duration: 364.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 0.0, duration: 299.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 0.0, duration: 668.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 0.0, duration: 626.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 0.0, duration: 539.0, mediaType: .audioMPEG)
    ]

    func testTocManifest() throws {
        validate(manifest: "toc_manifest", against: tocManaifestExpectedResults)
    }

    func testNonTockManifest() throws {
        validate(manifest: "non_toc_manifest", against: nonTocManifestExpeectedResults)
    }

    private func validate(manifest: String, against results: [TestOutcome]) {
        let bundle = Bundle(for: AudiobookTOCTests.self)
        let url = bundle.url(forResource: manifest, withExtension: "json")!

        guard let lcpAudiobook = try? fetchAudiobook(url: url),
                let spine = lcpAudiobook?.spine as? [LCPSpineElement] else {
            XCTFail("Failed to create Audiobook spine.")
            return
        }

        for (index, element) in spine.enumerated() {
            XCTAssertEqual(element.chapterNumber, results[index].chapter)
            XCTAssertEqual(element.offset, results[index].offset)
            XCTAssertEqual(element.duration, results[index].duration)
            XCTAssertEqual(element.mediaType, results[index].mediaType)
        }
    }

    private func fetchAudiobook(url: URL) throws -> LCPAudiobook? {
        let jsonData = try Data(contentsOf: url, options: .mappedIfSafe)
        let string = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        return LCPAudiobook(JSON: string, decryptor: nil)
    }
}
