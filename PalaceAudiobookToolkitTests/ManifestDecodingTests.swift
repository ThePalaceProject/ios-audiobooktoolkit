//
//  ManifestDecoderTest.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit


enum ManifestJSON: String, CaseIterable {
    case alice = "alice_manifest"
    case anathem = "anathem_manifest"
    case bigFail = "theBigFail_manifest"
    case christmasCarol = "christmas_carol_manifest"
    case flatland = "flatland_manifest"
    case bestNewHorror = "best_new_horror_manifest"
    case quickSilver = "quicksilver_manifest"
    case martian = "the_martian_manifest"
    case snowcrash = "snowcrash_manifest"
    case theSystemOfTheWorld = "the_system_of_the_world_manifest"

    var chapterCount: Int {
        switch self {
        case .alice: return 13
        case .anathem: return 17
        case .bigFail: return 22
        case .christmasCarol: return 6
        case .martian: return 41
        case .bestNewHorror: return 7
        case .quickSilver: return 29
        case .snowcrash: return 72
        case .theSystemOfTheWorld: return 47
        case .flatland: return 24
        }
    }
}

final class ManifestDecodingTests: XCTestCase {
    private let enableDataLogging = false
    
    func testManifestDecoding() {
        for manifestJSON in ManifestJSON.allCases {
            do {
                let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
                guard let jsonData = try? Data(contentsOf: Bundle(for: type(of: self)).url(forResource: manifestJSON.rawValue, withExtension: "json")!),
                      let jsonDictionary = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    XCTFail("Failed to load or parse \(manifestJSON.rawValue).json")
                    continue
                }
                validate(manifest: manifest, against: jsonDictionary)
            } catch {
                XCTFail("Decoding failed for \(manifestJSON.rawValue) with error: \(error)")
            }
        }
    }
    
    private func validate(manifest: Manifest, against jsonDictionary: [String: Any]) {
        // Reflect Manifest object to access its properties
        let mirror = Mirror(reflecting: manifest)
        
        // Check if each key in the JSON dictionary has a corresponding property in the Manifest object
        for (key, value) in jsonDictionary {
            let adjustedKey = (key == "@context") ? "context" : key
            guard let manifestProperty = mirror.children.first(where: { $0.label == adjustedKey }) else {
                XCTFail("Manifest does not contain a property for key: \(key)")
                continue
            }
            
            print("Validating \(adjustedKey)...")
            
            // Log the test data and actual data being compared
            if enableDataLogging {
                print("Test data: \(value)")
                print("Actual data: \(manifestProperty.value)")
            }
            
            // Custom checks for nested structures like arrays or dictionaries
            if let readingOrder = value as? [[String: Any]], adjustedKey == "readingOrder" {
                validateReadingOrderItems(manifest.readingOrder, against: readingOrder)
            } else if let toc = value as? [[String: Any]], adjustedKey == "toc" {
                validateTOCItems(manifest.toc, against: toc)
            } else if let links = value as? [[String: Any]], adjustedKey == "links" {
                validateLinks(manifest.links, against: links)
            } else if adjustedKey == "metadata" {
                if let jsonMetadata = value as? [String: Any] {
                    validateMetadata(manifest.metadata, against: jsonMetadata)
                }
            } else if adjustedKey == "resources" {
                if let jsonResources = value as? [[String: Any]] {
                    validateLinks(manifest.resources ?? [], against: jsonResources)
                }
            } else {
                // Direct comparison for properties that are not arrays or dictionaries
                if let valueAsString = value as? String, let propertyValueAsString = manifestProperty.value as? String {
                    XCTAssertEqual(propertyValueAsString, valueAsString, "Value mismatch for key: \(key)")
                    print("✅ Validation successful for \(adjustedKey)")
                } else if let valueAsInt = value as? Int, let propertyValueAsInt = manifestProperty.value as? Int {
                    XCTAssertEqual(propertyValueAsInt, valueAsInt, "Value mismatch for key: \(key)")
                    print("✅ Validation successful for \(adjustedKey)")
                } else {
                    XCTAssertEqual(String(describing: manifestProperty), String(describing: value), "Value mismatch for key: \(key)")
                    print("✅ Validation successful for \(adjustedKey)")
                }
            }
        }
    }
    
    private func validateMetadata(_ manifestMetadata: Metadata, against jsonMetadata: [String: Any]) {
        XCTAssertEqual(manifestMetadata.type, jsonMetadata["@type"] as? String)
        XCTAssertEqual(manifestMetadata.identifier, jsonMetadata["identifier"] as? String)
        XCTAssertEqual(manifestMetadata.title, jsonMetadata["title"] as? String)
        XCTAssertEqual(manifestMetadata.subtitle, jsonMetadata["subtitle"] as? String)
        XCTAssertEqual(manifestMetadata.language, jsonMetadata["language"] as? String)
        XCTAssertEqual(manifestMetadata.duration, jsonMetadata["duration"] as? Int)
        // Handle dates
        if let modifiedString = jsonMetadata["modified"] as? String {
            let dateFormatter = ISO8601DateFormatter()
            if let modifiedDate = dateFormatter.date(from: modifiedString) {
                XCTAssertEqual(manifestMetadata.modified, modifiedDate)
            }
        }
        // Handle complex fields like author
        if let jsonAuthors = jsonMetadata["author"] as? [String] {
            for (index, author) in manifestMetadata.author.enumerated() {
                guard index < jsonAuthors.count else { continue }
                let jsonAuthor = jsonAuthors[index]
                XCTAssertEqual(author.name, jsonAuthor)
            }
        } else if let jsonAuthor = jsonMetadata["author"] as? [String: Any] {
            manifestMetadata.author.forEach {
                XCTAssertEqual($0.name, jsonAuthor["name"] as? String)
            }
        } else if let jsonAuthor =  jsonMetadata["author"] as? String {
            manifestMetadata.author.forEach {
                XCTAssertEqual($0.name, jsonAuthor)
            }
        }
    }
    
    
    private func validateReadingOrderItems(_ items: [ReadingOrderItem], against json: [[String: Any]]) {
        XCTAssertEqual(items.count, json.count, "ReadingOrder count does not match")
        for (index, item) in items.enumerated() {
            let itemJson = json[index]
            XCTAssertEqual(item.href, itemJson["href"] as! String, "ReadingOrderItem href does not match at index \(index)")
            XCTAssertEqual(item.title, itemJson["title"] as? String, "ReadingOrderItem title does not match at index \(index)")
        }
    }
    
    private func validateTOCItems(_ items: [TOCItem]?, against json: [[String: Any]]?) {
        XCTAssertEqual(items?.count ?? 0, json?.count ?? 0, "TOC count does not match")
        for (index, item) in (items ?? []).enumerated() {
            guard let itemJson = json?[index] else { continue }
            XCTAssertEqual(item.href, itemJson["href"] as? String, "TOCItem href does not match at index \(index)")
            XCTAssertEqual(item.title, itemJson["title"] as? String, "TOCItem title does not match at index \(index)")
        }
    }
    
    private func validateLinks(_ manifestLinks: [Link], against jsonLinks: [[String: Any]]) {
        XCTAssertEqual(manifestLinks.count, jsonLinks.count, "Link count mismatch")
        
        for (index, manifestLink) in manifestLinks.enumerated() {
            guard index < jsonLinks.count else {
                XCTFail("Index out of bounds for JSON links array")
                break
            }
            
            let jsonLink = jsonLinks[index]
            
            if let rel = jsonLink["rel"] as? String {
                XCTAssertEqual(manifestLink.rel, rel, "Rel mismatch in link at index \(index)")
            }
            
            if let href = jsonLink["href"] as? String {
                XCTAssertEqual(manifestLink.href, href, "Href mismatch in link at index \(index)")
            }
            
            if let type = jsonLink["type"] as? String {
                XCTAssertEqual(manifestLink.type, type, "Type mismatch in link at index \(index)")
            }
            
            if let height = jsonLink["height"] as? Int {
                XCTAssertEqual(manifestLink.height, height, "Height mismatch in link at index \(index)")
            } else {
                XCTAssertNil(manifestLink.height, "Expected height to be nil in link at index \(index)")
            }
            
            if let width = jsonLink["width"] as? Int {
                XCTAssertEqual(manifestLink.width, width, "Width mismatch in link at index \(index)")
            } else {
                XCTAssertNil(manifestLink.width, "Expected width to be nil in link at index \(index)")
            }
        }
    }
    
    func testFalseNegative() {
        // Simulate a false negative case
        let jsonData = Data()
        let decoder = Manifest.customDecoder()
        do {
            _ = try decoder.decode(Manifest.self, from: jsonData)
            XCTFail("False negative test succeeded unexpectedly")
        } catch {
            // This is the expected behavior
            XCTAssert(true)
        }
    }
}

extension Manifest {
    static func from(jsonFileName: String, bundle: Bundle = .main) throws -> Manifest {
        guard let url = bundle.url(forResource: jsonFileName, withExtension: "json"),
              let jsonData = try? Data(contentsOf: url) else {
            throw NSError(domain: "ManifestLoadingError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Failed to load \(jsonFileName).json"])
        }
        
        let decoder = Manifest.customDecoder()
        return try decoder.decode(Manifest.self, from: jsonData)
    }
}

