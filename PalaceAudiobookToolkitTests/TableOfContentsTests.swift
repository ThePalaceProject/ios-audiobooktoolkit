//
//  TableOfContentsTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/15/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class TableOfContentsTests: XCTestCase {
    private let testID = "testID"
    
    func testTableOfContentsWithManifests() {
        for manifestJSON in ManifestJSON.allCases {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: Tracks(manifest: manifest, audiobookID: testID))
                XCTAssertFalse(tableOfContents.toc.isEmpty, "TOC should not be empty for \(manifestJSON.rawValue)")
                
                if let firstChapter = tableOfContents.toc.first {
                    XCTAssertFalse(firstChapter.title.isEmpty, "First chapter title should not be empty in \(manifestJSON.rawValue)")
                }
            } catch {
                XCTFail("Decoding failed for \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }

    func testChapterCounts() {
        for manifestJSON in ManifestJSON.allCases {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                let tracks = Tracks(manifest: manifest, audiobookID: testID)
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
                
                let expectedCount = manifestJSON.chapterCount
                XCTAssertEqual(tableOfContents.toc.count, expectedCount, "Expected \(expectedCount) chapters in \(manifestJSON.rawValue), but found \(tableOfContents.toc.count)")
            } catch {
                XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    func testSpecificChapterTitles() {
        let expectedFirstChapterTitles: [ManifestJSON: String] = [
            .alice: "Opening Credits",
            .anathem: "Epigraph",
            .bigFail: "Chapter 1",
            .bocas: "Chapter: 1",
            .christmasCarol: "Opening Credits",
            .flatland: "Forward",
            .martian: "Opening Credits",
            .bestNewHorror: "Chapter 1",
            .quickSilver: "Invocation",
            .snowcrash: "Opening Credits",
            .theSystemOfTheWorld: "Chapter 1"
        ]
        
        for (manifestJSON, expectedTitle) in expectedFirstChapterTitles {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: Tracks(manifest: manifest, audiobookID: testID))
                
                let firstChapterTitle = tableOfContents.toc.first?.title ?? ""
                XCTAssertEqual(firstChapterTitle, expectedTitle, "Expected first chapter title to be \"\(expectedTitle)\" in \(manifestJSON.rawValue), but found \"\(firstChapterTitle)\"")
            } catch {
                XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    func testChapterDurationCalculations() {
        let expectedDurations: [ManifestJSON: [Double]] = [
//            .animalFarm: [7416, 7684, 3821],
//                .flatland: [
//                    9.0, 335.0, 374.0, 600.0, 864.0, 804.0, 931.0, 575.0, 448.0, 659.0,
//                    691.0, 435.0, 790.0, 8.0, 777.0, 1421.0, 0.0, 1164.0, 374.0, 965.0,
//                    1117.0, 582.0, 437.0, 722.0
//                ],
//            .bestNewHorror: [
//                487.0, 437.0, 364.0, 299.0, 668.0, 626.0, 539.0
//            ],
//            .martian: [
//                28.0, 1.0, 782.0, 2.0, 335.0, 179.0, 7.0, 231.0, 66.0, 151.0,
//                122.0, 2.0, 300.0, 180.0, 206.0, 387.0, 2.0, 208.0, 131.0, 302.0,
//                110.0, 264.0, 2.0, 158.0, 10.0, 110.0, 536.0, 312.0, 105.0, 1509.0,
//                13.0, 3.0, 356.0, 183.0, 187.0, 57.0, 118.0, 234.0, 211.0, 117.0,
//                222.0
//            ],
//            .snowcrash: [
//                75.0, 1388.0, 955.0, 1146.0, 1161.0, 1158.0, 1278.0, 1196.0, 699.0,
//                945.0, 961.0, 538.0, 1621.0, 1214.0, 1411.0, 1089.0, 1054.0, 884.0,
//                591.0, 1267.0, 535.0, 1102.0, 806.0, 786.0, 1157.0, 787.0, 837.0,
//                1084.0, 799.0, 1006.0, 1046.0, 882.0, 988.0, 1199.0, 1066.0, 584.0,
//                1133.0, 1214.0, 470.0, 1110.0, 668.0, 1234.0, 656.0, 808.0, 937.0,
//                686.0, 350.0, 691.0, 1197.0, 1321.0, 494.0, 1017.0, 1018.0, 743.0,
//                68.0, 522.0, 1232.0, 738.0, 883.0, 528.0, 910.0, 666.0, 105.0, 720.0,
//                186.0, 653.0, 560.0, 642.0, 532.0, 656.0, 461.0, 323.0
//            ],
//            .christmasCarol: [
//                76.0, 2982.0, 2649.0, 3598.0, 2375.0, 1026.0
//            ],
//            .anathem: [
//                57.0, 38.0, 641.0, 6908.0, 13428.0, 3879.0, 6275.0, 9684.0, 9865.0,
//                15743.0, 8391.0, 6339.0, 13220.0, 15100.0, 5526.0, 1574.0, 64.0
//            ],
//            .theSystemOfTheWorld: [
//                131.0, 1393.0, 645.0, 651.0, 1011.0, 2952.0, 4388.0, 713.0, 1838.0, 820.0
//            ],
//            .quickSilver: [
//                125.0, 3.0, 3435.0, 1680.0, 2738.0, 2000.0, 1141.0, 552.0, 157.0,
//                309.0, 1002.0, 1270.0, 378.0, 3248.0, 5413.0, 460.0, 2028.0, 781.0,
//                2413.0, 5518.0, 723.0, 2281.0, 3556.0, 2944.0, 511.0, 2885.0, 806.0,
//                3918.0, 751.0
//            ],
            .bigFail: [
                15.0, 7.0, 586.0, 3061.0, 2740.0, 2177.0, 2395.0, 2230.0, 4218.0,
                1991.0, 2830.0, 1533.0, 2811.0, 1752.0, 2367.0, 2863.0, 3025.0,
                2596.0, 2296.0, 3019.0, 2006.0, 36.0
            ]
        ]
        
        for (manifestJSON, expectedChapterDurations) in expectedDurations {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                let tracks = Tracks(manifest: manifest, audiobookID: testID)
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
                
                // Test each chapter's duration against the expected value.
                for (index, expectedDuration) in expectedChapterDurations.enumerated() {
                    guard index < tableOfContents.toc.count else {
                        XCTFail("Chapter index \(index) out of range for \(manifestJSON.rawValue)")
                        continue
                    }
                    
                    let tocItem = tableOfContents.toc[index]
                    if let duration = tocItem.duration {
                        XCTAssertEqual(duration, expectedDuration, accuracy: 0.1, "Chapter \(index + 1) duration mismatch in \(manifestJSON.rawValue).")
                    } else {
                        XCTFail("Expected duration for Chapter \(index + 1) is nil in \(manifestJSON.rawValue)")
                    }
                }
            } catch {
                XCTFail("Failed to load \(manifestJSON.rawValue) with error: \(error.localizedDescription)")
            }
        }
    }

    
    func loadManifest(for manifestJSON: ManifestJSON) throws -> Manifest {
        return try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
    }
}
