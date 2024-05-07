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
                
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: Tracks(manifest: manifest, audiobookID: testID, token: nil))
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
                let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
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
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: Tracks(manifest: manifest, audiobookID: testID, token: nil))
                
                let firstChapterTitle = tableOfContents.toc.first?.title ?? ""
                XCTAssertEqual(firstChapterTitle, expectedTitle, "Expected first chapter title to be \"\(expectedTitle)\" in \(manifestJSON.rawValue), but found \"\(firstChapterTitle)\"")
            } catch {
                XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    func testChapterDurationCalculations() {
        for manifestJSON in [ManifestJSON.bigFail] {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
                let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
                
                // Test each chapter's duration against the expected value.
                for (index, expectedDuration) in manifestJSON.chapterDurations.enumerated() {
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
