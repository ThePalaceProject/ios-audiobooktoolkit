//
//  ManifestDecoderTest.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class ManifestDecodingTests: XCTestCase {
    private let enableDataLogging = true
    
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
        let mirror = Mirror(reflecting: manifest)
        
        for (key, value) in jsonDictionary {
            let adjustedKey = key == "@context" ? "context" : key
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
            
            switch adjustedKey {
            case "context":
                if let jsonContexts = value as? [Any] {
                    validateContext(manifestContexts: manifest.context, against: jsonContexts)
                } else if let jsonContext = value as? String {
                    validateContext(manifestContexts: manifest.context, against: [jsonContext])
                } else {
                    XCTFail("Unexpected @context format")
                }
            case "readingOrder":
                if let readingOrder = value as? [[String: Any]] {
                    validateReadingOrderItems(manifest.readingOrder!, against: readingOrder)
                }
            case "toc":
                if let toc = value as? [[String: Any]] {
                    validateTOCItems(manifest.toc ?? [], against: toc)
                }
            case "links":
                if let linksArray = value as? [[String: Any]] {
                    validateLinks(manifest.links ?? [], against: linksArray)
                } else if let linksDict = value as? [String: Any], let contentLinks = linksDict["contentlinks"] as? [[String: Any]] {
                    // Assuming you have logic to handle linksDictionary in Manifest
                    validateLinks(manifest.linksDictionary?.contentLinks ?? [], against: contentLinks)
                }
            case "metadata":
                if let jsonMetadata = value as? [String: Any], let metadata = manifest.metadata {
                    validateMetadata(metadata, against: jsonMetadata)
                }
            case "resources":
                if let jsonResources = value as? [[String: Any]] {
                    validateLinks(manifest.resources ?? [], against: jsonResources)
                }
            case "spine":
                if let spineArray = value as? [[String: Any]] {
                    validateSpineItems(manifest.spine ?? [], against: spineArray)
                }
            default:
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
}

private func validateContext(manifestContexts: [ManifestContext], against jsonContexts: [Any]) {
    for (index, jsonContext) in jsonContexts.enumerated() {
        guard index < manifestContexts.count else {
            XCTFail("JSON context array has more items than the manifest context array.")
            return
        }
        
        let manifestContext = manifestContexts[index]
        
        if let contextString = jsonContext as? String {
            switch manifestContext {
            case .uri(let uri):
                XCTAssertEqual(uri.absoluteString, contextString, "URI context mismatch at index \(index)")
            case .other(let otherString):
                XCTAssertEqual(otherString, contextString, "String context mismatch at index \(index)")
            default:
                XCTFail("Expected URI or string context at index \(index)")
            }
        } else if let contextDict = jsonContext as? [String: String], let (key, expectedValue) = contextDict.first {
            // Handle case where JSON context is a dictionary.
            switch manifestContext {
            case .object(let objectDict):
                guard let objectValue = objectDict[key] else {
                    XCTFail("Key '\(key)' not found in manifest context object at index \(index)")
                    return
                }
                XCTAssertEqual(objectValue, expectedValue, "Context object value mismatch for key '\(key)' at index \(index)")
            default:
                XCTFail("Expected object context at index \(index)")
            }
        } else {
            XCTFail("Unexpected JSON context format at index \(index)")
        }
    }
    
    XCTAssertEqual(manifestContexts.count, jsonContexts.count, "Manifest context array and JSON context array have different lengths.")
}

private func validateStringContext(_ manifestContext: ManifestContext, contextString: String, index: Int) {
    if case .uri(let urlString) = manifestContext {
        XCTAssertEqual(urlString.absoluteString, contextString, "Context URL string mismatch at index \(index)")
    } else if case .other(let urlString) = manifestContext {
        XCTAssertEqual(urlString, contextString, "Context URL string mismatch at index \(index)")
    } else {
        XCTFail("Expected a URL string at index \(index)")
    }
}

private func validateDictionaryContext(_ manifestContext: ManifestContext, contextDict: [String: String], index: Int) {
    // This assumes dictionary context always contains a single key-value pair.
    let (key, value) = contextDict.first!
    if case .object(let objectDict) = manifestContext, let objectValue = objectDict[key] {
        XCTAssertEqual(objectValue, value, "Context object value mismatch for key '\(key)' at index \(index)")
    } else {
        XCTFail("Expected an object with key '\(key)' at index \(index)")
    }
}

private func validateSpineItems(_ spineItems: [Manifest.SpineItem], against jsonSpineItems: [[String: Any]]) {
    XCTAssertEqual(spineItems.count, jsonSpineItems.count, "Spine count does not match")
    
    for (index, spineItem) in spineItems.enumerated() {
        guard index < jsonSpineItems.count else {
            XCTFail("Index out of bounds for JSON spine array")
            break
        }
        
        let jsonSpineItem = jsonSpineItems[index]
        XCTAssertEqual(spineItem.title, jsonSpineItem["title"] as? String, "Title mismatch in spine at index \(index)")
        XCTAssertEqual(spineItem.href, jsonSpineItem["href"] as? String, "Href mismatch in spine at index \(index)")
        XCTAssertEqual(spineItem.type, jsonSpineItem["type"] as? String, "Type mismatch in spine at index \(index)")
        XCTAssertEqual(spineItem.duration, jsonSpineItem["duration"] as? Int, "Duration mismatch in spine at index \(index)")
    }
}


private func validateMetadata(_ manifestMetadata: Manifest.Metadata, against jsonMetadata: [String: Any]) {
    XCTAssertEqual(manifestMetadata.type, jsonMetadata["@type"] as? String)
    XCTAssertEqual(manifestMetadata.identifier, jsonMetadata["identifier"] as? String)
    XCTAssertEqual(manifestMetadata.title, jsonMetadata["title"] as? String)
    XCTAssertEqual(manifestMetadata.subtitle, jsonMetadata["subtitle"] as? String)
    XCTAssertEqual(manifestMetadata.language, jsonMetadata["language"] as? String)
    XCTAssertEqual(manifestMetadata.duration, jsonMetadata["duration"] as? Double)
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
    
    if let drmInfo = jsonMetadata["encrypted"] as? [String: Any] {
        switch manifestMetadata.drmInformation {
        case .findaway(let findawayInfo):
            XCTAssertEqual(findawayInfo.scheme, drmInfo["scheme"] as? String, "DRM scheme does not match")
            XCTAssertEqual(findawayInfo.licenseId, drmInfo["findaway:licenseId"] as? String, "Findaway licenseId does not match")
            XCTAssertEqual(findawayInfo.sessionKey, drmInfo["findaway:sessionKey"] as? String, "Findaway sessionKey does not match")
            XCTAssertEqual(findawayInfo.checkoutId, drmInfo["findaway:checkoutId"] as? String, "Findaway checkoutId does not match")
            XCTAssertEqual(findawayInfo.fulfillmentId, drmInfo["findaway:fulfillmentId"] as? String, "Findaway fulfillmentId does not match")
            XCTAssertEqual(findawayInfo.accountId, drmInfo["findaway:accountId"] as? String, "Findaway accountId does not match")
        default:
            XCTFail("Expected Findaway DRM information")
        }
    } else {
        XCTAssertNil(manifestMetadata.drmInformation, "Expected nil DRM information")
    }
}


private func validateReadingOrderItems(_ items: [Manifest.ReadingOrderItem], against json: [[String: Any]]) {
    XCTAssertEqual(items.count, json.count, "ReadingOrder count does not match")
    for (index, item) in items.enumerated() {
        let itemJson = json[index]
        XCTAssertEqual(item.href, itemJson["href"] as? String, "ReadingOrderItem href does not match at index \(index)")
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

private func validateLinks(_ manifestLinks: [Manifest.Link], against jsonLinks: [[String: Any]]) {
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


enum ManifestJSON: String, CaseIterable {
    case alice = "alice_manifest"
    case anathem = "anathem_manifest"
    case animalFarm = "animalFarm_manifest"
    case bigFail = "theBigFail_manifest"
    case bocas = "bocas_manifest"
    case christmasCarol = "christmas_carol_manifest"
    case flatland = "flatland_manifest"
    case bestNewHorror = "best_new_horror_manifest"
    case quickSilver = "quicksilver_manifest"
    case littleWomenDevotional = "littleWomenDevotional_manifest"
    case martian = "the_martian_manifest"
    case snowcrash = "snowcrash_manifest"
    case secretLives = "secret_lives_manifest"
    case theSystemOfTheWorld = "the_system_of_the_world_manifest"
    
    var chapterCount: Int {
        switch self {
        case .alice: return 13
        case .anathem: return 17
        case .animalFarm: return 3
        case .bigFail: return 22
        case .bocas: return 14
        case .christmasCarol: return 6
        case .flatland: return 25
        case .littleWomenDevotional: return 54
        case .martian: return 41
        case .bestNewHorror: return 7
        case .quickSilver: return 29
        case .snowcrash: return 72
        case .secretLives: return 10
        case .theSystemOfTheWorld: return 47
        }
    }
    
    var chapterDurations: [Double] {
        switch self {
        case .bigFail:
            return [
                15.0, 7.0, 586.0, 3061.0, 2740.0, 2177.0, 2395.0, 2230.0, 4218.0,
                1991.0, 2830.0, 1533.0, 2811.0, 1752.0, 2367.0, 2863.0, 3025.0,
                2596.0, 2296.0, 3019.0, 2006.0, 36.0
            ]
        case .snowcrash:
            return [
                75.0, 1388.0, 955.0, 1146.0, 1161.0, 1158.0, 1278.0, 1196.0, 699.0,
                945.0, 961.0, 538.0, 1621.0, 1214.0, 1411.0, 1089.0, 1054.0, 884.0,
                591.0, 1267.0, 535.0, 1102.0, 806.0, 786.0, 1157.0, 787.0, 837.0, 1084.0,
                799.0, 1006.0, 1046.0, 882.0, 988.0, 1199.0, 1066.0, 584.0, 1133.0, 1214.0,
                470.0, 1110.0, 668.0, 1234.0, 656.0, 808.0, 937.0, 686.0, 350.0, 691.0,
                1197.0, 1321.0, 494.0, 1017.0, 1018.0, 743.0, 68.0, 522.0, 1232.0, 738.0,
                883.0, 528.0, 910.0, 666.0, 105.0, 720.0, 186.0, 653.0, 560.0, 642.0,
                532.0, 656.0, 461.0, 323.0
            ]
        default:
            return []
        }
    }
    
    var chapterOffset: [Int] {
        switch self {
        case .snowcrash:
            return [
                0, 75, 1463, 2418, 626, 1787, 12, 1290, 2486, 326, 1271, 2232, 13, 1634, 13,
                1424, 2513, 768, 1652, 2243, 939, 1474, 15, 821, 1607, 280, 1067, 1904, 686,
                1485, 17, 1063, 18, 1006, 2205, 751, 1335, 19, 1233, 1703, 19, 687, 1921, 20,
                828, 1765, 20, 370, 1061, 20, 1341, 1835, 21, 1039, 1782, 1850, 21, 1253, 1991,
                21, 549, 1459, 2125, 2230, 398, 584, 1237, 1797, 22, 554, 1210, 1671
            ]
        default:
            return []
        }
    }
}
