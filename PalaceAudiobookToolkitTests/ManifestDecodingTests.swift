//
//  ManifestDecoderTest.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

// MARK: - ManifestDecodingTests

final class ManifestDecodingTests: XCTestCase {
  private let enableDataLogging = true

  func testManifestDecoding() {
    for manifestJSON in ManifestJSON.allCases {
      do {
        let manifest = try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
        guard let jsonData = try? Data(contentsOf: Bundle(for: type(of: self)).url(
          forResource: manifestJSON.rawValue,
          withExtension: "json"
        )!),
          let jsonDictionary = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
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
        } else if let linksDict = value as? [String: Any],
                  let contentLinks = linksDict["contentlinks"] as? [[String: Any]]
        {
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
          XCTAssertEqual(
            String(describing: manifestProperty),
            String(describing: value),
            "Value mismatch for key: \(key)"
          )
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
      case let .uri(uri):
        XCTAssertEqual(uri.absoluteString, contextString, "URI context mismatch at index \(index)")
      case let .other(otherString):
        XCTAssertEqual(otherString, contextString, "String context mismatch at index \(index)")
      default:
        XCTFail("Expected URI or string context at index \(index)")
      }
    } else if let contextDict = jsonContext as? [String: String], let (key, expectedValue) = contextDict.first {
      // Handle case where JSON context is a dictionary.
      switch manifestContext {
      case let .object(objectDict):
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

  XCTAssertEqual(
    manifestContexts.count,
    jsonContexts.count,
    "Manifest context array and JSON context array have different lengths."
  )
}

private func validateStringContext(_ manifestContext: ManifestContext, contextString: String, index: Int) {
  if case let .uri(urlString) = manifestContext {
    XCTAssertEqual(urlString.absoluteString, contextString, "Context URL string mismatch at index \(index)")
  } else if case let .other(urlString) = manifestContext {
    XCTAssertEqual(urlString, contextString, "Context URL string mismatch at index \(index)")
  } else {
    XCTFail("Expected a URL string at index \(index)")
  }
}

private func validateDictionaryContext(_ manifestContext: ManifestContext, contextDict: [String: String], index: Int) {
  // This assumes dictionary context always contains a single key-value pair.
  let (key, value) = contextDict.first!
  if case let .object(objectDict) = manifestContext, let objectValue = objectDict[key] {
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
    XCTAssertEqual(
      spineItem.duration,
      jsonSpineItem["duration"] as? Int,
      "Duration mismatch in spine at index \(index)"
    )
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
      guard index < jsonAuthors.count else {
        continue
      }
      let jsonAuthor = jsonAuthors[index]
      XCTAssertEqual(author.name, jsonAuthor)
    }
  } else if let jsonAuthor = jsonMetadata["author"] as? [String: Any] {
    manifestMetadata.author.forEach {
      XCTAssertEqual($0.name, jsonAuthor["name"] as? String)
    }
  } else if let jsonAuthor = jsonMetadata["author"] as? String {
    manifestMetadata.author.forEach {
      XCTAssertEqual($0.name, jsonAuthor)
    }
  }

  if let drmInfo = jsonMetadata["encrypted"] as? [String: Any] {
    switch manifestMetadata.drmInformation {
    case let .findaway(findawayInfo):
      XCTAssertEqual(findawayInfo.scheme, drmInfo["scheme"] as? String, "DRM scheme does not match")
      XCTAssertEqual(
        findawayInfo.licenseId,
        drmInfo["findaway:licenseId"] as? String,
        "Findaway licenseId does not match"
      )
      XCTAssertEqual(
        findawayInfo.sessionKey,
        drmInfo["findaway:sessionKey"] as? String,
        "Findaway sessionKey does not match"
      )
      XCTAssertEqual(
        findawayInfo.checkoutId,
        drmInfo["findaway:checkoutId"] as? String,
        "Findaway checkoutId does not match"
      )
      XCTAssertEqual(
        findawayInfo.fulfillmentId,
        drmInfo["findaway:fulfillmentId"] as? String,
        "Findaway fulfillmentId does not match"
      )
      XCTAssertEqual(
        findawayInfo.accountId,
        drmInfo["findaway:accountId"] as? String,
        "Findaway accountId does not match"
      )
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
    guard let itemJson = json?[index] else {
      continue
    }
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
