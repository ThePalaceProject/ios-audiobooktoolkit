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
    func testTableOfContentsWithManifests() {
        for manifestJSON in ManifestJSON.allCases {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                
                let tableOfContents = TableOfContents(manifest: manifest, tracks: TPPTracks(manifest: manifest))
                XCTAssertFalse(tableOfContents.toc.isEmpty, "TOC should not be empty for \(manifestJSON.rawValue)")
                
                if let firstChapter = tableOfContents.toc.first {
                    XCTAssertFalse(firstChapter.title.isEmpty, "First chapter title should not be empty in \(manifestJSON.rawValue)")
                }
            } catch {
                XCTFail("Decoding failed for \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    // Tests the expected chapter counts for each manifest.
    func testChapterCounts() {
        for manifestJSON in ManifestJSON.allCases {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                let tracks = TPPTracks(manifest: manifest)
                let tableOfContents = TableOfContents(manifest: manifest, tracks: tracks)
                
                // Directly access the chapterCount for the manifestJSON case.
                let expectedCount = manifestJSON.chapterCount
                XCTAssertEqual(tableOfContents.toc.count, expectedCount, "Expected \(expectedCount) chapters in \(manifestJSON.rawValue), but found \(tableOfContents.toc.count)")
            } catch {
                XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    // Tests for specific chapter titles to ensure they match expectations.
    func testSpecificChapterTitles() {
        let expectedFirstChapterTitles: [ManifestJSON: String] = [
            .alice: "Opening Credits",
            .anathem: "Epigraph",
            .bigFail: "Chapter 1",
            .christmasCarol: "Opening Credits",
            .flatland: "Part 1 - This World",
            .martian: "Opening Credits",
            .nonTocManifest: "Chapter 1",
            .quickSilver: "Invocation",
            .snowcrash: "Opening Credits",
            .theSystemOfTheWorld: "Chapter 1"
        ]
        
        for (manifestJSON, expectedTitle) in expectedFirstChapterTitles {
            do {
                let manifest = try loadManifest(for: manifestJSON)
                let tableOfContents = TableOfContents(manifest: manifest, tracks: TPPTracks(manifest: manifest))
                
                let firstChapterTitle = tableOfContents.toc.first?.title ?? ""
                XCTAssertEqual(firstChapterTitle, expectedTitle, "Expected first chapter title to be \"\(expectedTitle)\" in \(manifestJSON.rawValue), but found \"\(firstChapterTitle)\"")
            } catch {
                XCTFail("Failed loading \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    private func loadManifest(for manifestJSON: ManifestJSON) throws -> Manifest {
        return try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
    }
}