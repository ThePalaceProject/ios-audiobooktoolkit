//
//  ConcurrencySafetyPrimitivesTests.swift
//  PalaceAudiobookToolkitTests
//
//  Covers the primitives introduced to replace global mutable state during the
//  Swift 6 strict-concurrency migration (PP-4724), plus the associated-object
//  storage that was rekeyed as part of it.
//
//  The associated-object cases matter disproportionately: rekeying touches the
//  getter and the setter independently, and a mismatch between the two is
//  silent at runtime — the property simply always reads back `nil`. Nothing in
//  the compiler catches that, so it is asserted here.
//

import AVFoundation
import XCTest

@testable import PalaceAudiobookToolkit

final class ConcurrencySafetyPrimitivesTests: XCTestCase {
  // MARK: - LockIsolated

  func testWithValue_UnderConcurrentIncrements_LosesNoWrites() {
    let box = LockIsolated(0)
    let iterations = 1000

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      box.withValue { $0 += 1 }
    }

    // A read-modify-write built from separate `get` then `set` would interleave
    // and drop increments here; only the atomic `withValue` preserves all of them.
    XCTAssertEqual(box.value, iterations)
  }

  func testValue_ReplacesWrappedValue() {
    let box = LockIsolated<String?>(nil)
    XCTAssertNil(box.value)

    box.value = "installed"

    XCTAssertEqual(box.value, "installed")
  }

  func testWithValue_ReturnsBodyResult() {
    let box = LockIsolated([1, 2, 3])

    let count = box.withValue { values -> Int in
      values.append(4)
      return values.count
    }

    XCTAssertEqual(count, 4)
    XCTAssertEqual(box.value, [1, 2, 3, 4])
  }

  // MARK: - AssociatedObjectKey

  func testAssociatedObjectKey_DistinctInstancesDoNotCollide() {
    let first = AssociatedObjectKey()
    let second = AssociatedObjectKey()

    // Each key must own a unique address. If this ever became a shared constant,
    // two properties keyed off it would silently overwrite each other.
    XCTAssertNotEqual(first.rawValue, second.rawValue)
  }

  // MARK: - AVPlayerItem.trackIdentifier

  func testTrackIdentifier_RoundTripsThroughAssociatedStorage() {
    let item = AVPlayerItem(url: URL(string: "https://example.org/track-1.mp3")!)

    item.trackIdentifier = "track-1"

    // Fails if the getter and setter are keyed off different addresses.
    XCTAssertEqual(item.trackIdentifier, "track-1")
  }

  func testTrackIdentifier_IsPerItemNotShared() {
    let first = AVPlayerItem(url: URL(string: "https://example.org/track-1.mp3")!)
    let second = AVPlayerItem(url: URL(string: "https://example.org/track-2.mp3")!)

    first.trackIdentifier = "track-1"
    second.trackIdentifier = "track-2"

    XCTAssertEqual(first.trackIdentifier, "track-1")
    XCTAssertEqual(second.trackIdentifier, "track-2")
  }

  func testTrackIdentifier_DefaultsToNilAndClearsBackToNil() {
    let item = AVPlayerItem(url: URL(string: "https://example.org/track-3.mp3")!)
    XCTAssertNil(item.trackIdentifier)

    item.trackIdentifier = "track-3"
    XCTAssertEqual(item.trackIdentifier, "track-3")

    item.trackIdentifier = nil
    XCTAssertNil(item.trackIdentifier)
  }

  // MARK: - PalaceAuthTokenProvider

  func testTokenResolver_IsReadableAfterInstallation() {
    let original = PalaceAuthTokenProvider.tokenResolver
    defer { PalaceAuthTokenProvider.tokenResolver = original }

    PalaceAuthTokenProvider.tokenResolver = { "bearer-abc" }

    XCTAssertEqual(PalaceAuthTokenProvider.currentToken, "bearer-abc")
  }

  func testTokenResolver_ConcurrentReadsAndWritesNeverTearTheResolver() {
    let original = PalaceAuthTokenProvider.tokenResolver
    defer { PalaceAuthTokenProvider.tokenResolver = original }

    PalaceAuthTokenProvider.tokenResolver = { "bearer-a" }
    let observed = LockIsolated<[String?]>([])

    // Readers AND writers must race for this to mean anything: with only
    // readers it passes against a plain `static var` too, and would be a test
    // of `LockIsolated` rather than of the provider. The app installs the
    // resolver at launch and the toolkit reads it off the main thread during
    // streaming playback, so a concurrent reinstall is the real shape.
    DispatchQueue.concurrentPerform(iterations: 500) { iteration in
      if iteration % 5 == 0 {
        PalaceAuthTokenProvider.tokenResolver = iteration % 10 == 0 ? { "bearer-a" } : { "bearer-b" }
      } else {
        observed.withValue { $0.append(PalaceAuthTokenProvider.currentToken) }
      }
    }

    // Every read must return one of the two installed resolvers' values —
    // never a torn or nil result from observing a half-assigned closure.
    XCTAssertFalse(observed.value.isEmpty)
    XCTAssertTrue(
      observed.value.allSatisfy { $0 == "bearer-a" || $0 == "bearer-b" },
      "A read observed neither installed resolver: \(Set(observed.value.map { $0 ?? "nil" }))"
    )
  }

  func testTokenResolver_ClearingRemovesTheToken() {
    let original = PalaceAuthTokenProvider.tokenResolver
    defer { PalaceAuthTokenProvider.tokenResolver = original }

    PalaceAuthTokenProvider.tokenResolver = { "bearer-xyz" }
    XCTAssertEqual(PalaceAuthTokenProvider.currentToken, "bearer-xyz")

    PalaceAuthTokenProvider.tokenResolver = nil

    XCTAssertNil(PalaceAuthTokenProvider.currentToken)
  }
}
