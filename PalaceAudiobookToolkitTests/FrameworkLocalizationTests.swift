//
//  FrameworkLocalizationTests.swift
//  PalaceAudiobookToolkitTests
//

import XCTest
@testable import PalaceAudiobookToolkit

/// The player's own strings are looked up with `bundle: Bundle.audiobookToolkit()`,
/// so they resolve against THIS framework's bundle — never the app's. The
/// framework shipped no `.lproj` at all, which meant every one of those strings
/// rendered English in German, Spanish, French and Italian. Nothing reported it,
/// because a runtime translation SDK swizzled the lookup and answered first; when
/// that SDK was removed the strings would silently have fallen back to `value:`.
///
/// These tests read the shipped bundle, not a fixture, so they fail if the
/// resources stop being copied.
final class FrameworkLocalizationTests: XCTestCase {

  private var frameworkBundle: Bundle {
    get throws {
      try XCTUnwrap(Bundle.audiobookToolkit(),
                    "the framework bundle identifier no longer resolves")
    }
  }

  func testGermanTableIsShippedInsideTheFramework() throws {
    let path = try XCTUnwrap(try frameworkBundle.path(forResource: "de", ofType: "lproj"),
                             "de.lproj is not in the framework bundle")
    let de = try XCTUnwrap(Bundle(path: path))
    // Foundation returns the KEY on a per-key miss, so an equal result means the
    // lookup found nothing — that is the failure this test exists to catch.
    let value = de.localizedString(forKey: "Decrease speed", value: nil, table: nil)
    XCTAssertNotEqual(value, "Decrease speed", "German table did not answer the lookup")
    XCTAssertEqual(value, "Geschwindigkeit verringern")
  }

  func testEveryShippedLanguageAnswersTheSameKeySet() throws {
    let bundle = try frameworkBundle
    var keysByLang: [String: Set<String>] = [:]
    for lang in ["en", "de", "es", "fr", "it"] {
      let path = try XCTUnwrap(bundle.path(forResource: lang, ofType: "lproj"),
                               "\(lang).lproj is not in the framework bundle")
      let table = try XCTUnwrap(
        NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String],
        "\(lang) Localizable.strings is not a readable strings table")
      keysByLang[lang] = Set(table.keys)
    }
    let every = keysByLang.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    for (lang, keys) in keysByLang.sorted(by: { $0.key < $1.key }) {
      XCTAssertEqual(every.subtracting(keys), [],
                     "\(lang) is missing keys that other languages carry; "
                     + "Foundation renders a missing key verbatim")
    }
  }

  func testTheHoursAndMinutesKeyIsAWellFormedFormatString() throws {
    // The key was `"%02d hr %02 dmin"` — a space between the width and the
    // conversion, which is not a valid specifier. The key is what a translator
    // is shown and what the table is keyed on, so a malformed one propagates.
    let bundle = try frameworkBundle
    for lang in ["en", "de", "es", "fr", "it"] {
      let path = try XCTUnwrap(bundle.path(forResource: lang, ofType: "lproj"))
      let table = try XCTUnwrap(
        NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String])
      for (key, value) in table {
        XCTAssertNil(key.range(of: #"%[-+ 0#]*[0-9]*\s+[a-zA-Z@]"#, options: .regularExpression),
                     "\(lang): malformed specifier in key \(key)")
        XCTAssertNil(value.range(of: #"%[-+ 0#]*[0-9]*\s+[a-zA-Z@]"#, options: .regularExpression),
                     "\(lang): malformed specifier in value \(value)")
      }
    }
  }

  func testHoursAndMinutesRendersBothNumbersInGerman() throws {
    // The whole point of the table: a real render, through the real lookup.
    let path = try XCTUnwrap(try frameworkBundle.path(forResource: "de", ofType: "lproj"))
    let de = try XCTUnwrap(Bundle(path: path))
    let format = de.localizedString(forKey: "%02d hr %02d min", value: nil, table: nil)
    XCTAssertEqual(String(format: format, 2, 5), "02 Std. 05 Min.")
  }
}
