//
//  LCPResourceLoaderColdLoadRetryTests.swift
//  PalaceAudiobookToolkitTests
//
//  Regression coverage for PP-4542: the LCP audiobook first-open "Audiobook
//  Unavailable" failure. AVPlayer's first-open metadata probe reads the tail of
//  the track; Readium 3.9.0 (PP-4340) / ReadiumZIPFoundation throws
//  Archive.ArchiveError.rangeOutOfBounds when a range's upperBound exceeds the
//  ZIP entry's uncompressedSize — i.e. the LCP resource reported a length larger
//  than it can serve, so the probe overshoots and the AVPlayerItem dead-ends.
//  Pre-3.2.0 Readium tolerated the short read; the bump made it throw.
//
//  These tests pin the CLAMP contract (read the largest readable prefix and
//  signal EOF rather than failing) WITHOUT a real AVAsset/Resource stack:
//    1. The classifier recognises a rangeOutOfBounds-shaped error.
//    2. A well-formed read within bounds → single-shot, full data.
//    3. An overshooting range → clamped to the real EOF (binary search), data
//       up to the boundary, reachedEOF == true.
//    4. A range starting past EOF → empty + reachedEOF (AVPlayer gets a clean
//       EOF, not a failure).
//    5. A non-bounds error → rethrown, never masked.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class LCPResourceLoaderColdLoadRetryTests: XCTestCase {

  private enum FakeReadError: Error, CustomStringConvertible {
    case rangeOutOfBounds
    case decryptionFailed
    var description: String {
      switch self {
      case .rangeOutOfBounds:
        return "decoding(ReadiumZIPFoundation.Archive.ArchiveError.rangeOutOfBounds)"
      case .decryptionFailed:
        return "decoding(ReadError.decryption(lcpPassphraseInvalid))"
      }
    }
  }

  /// A fake resource of `length` readable bytes: read(range) returns
  /// `range.count` bytes when within bounds, else throws rangeOutOfBounds —
  /// mirroring ZIPFoundation's `upperBound <= uncompressedSize` guard. Counts
  /// calls so we can assert well-formed reads stay single-shot.
  private final class FakeResource {
    let length: UInt64
    private(set) var reads = 0
    init(length: UInt64) { self.length = length }
    func read(_ range: Range<UInt64>) async throws -> Data {
      reads += 1
      guard range.upperBound <= length else { throw FakeReadError.rangeOutOfBounds }
      return Data(count: Int(range.upperBound - range.lowerBound))
    }
  }

  // 1. Classifier
  func testClassifier_recognisesRangeOutOfBounds() {
    XCTAssertTrue(LCPResourceLoaderDelegate.isRangeOutOfBoundsError(FakeReadError.rangeOutOfBounds))
    XCTAssertFalse(LCPResourceLoaderDelegate.isRangeOutOfBoundsError(FakeReadError.decryptionFailed))
  }

  // 2. Well-formed read within bounds → single-shot, full data.
  func testClamp_inBoundsReadIsSingleShot() async throws {
    let res = FakeResource(length: 10_000)
    let (data, eof) = try await LCPResourceLoaderDelegate.readClampedToAvailable(
      start: 0, requestedEnd: 4096
    ) { try await res.read($0) }
    XCTAssertEqual(data.count, 4096)
    XCTAssertFalse(eof, "a full read shorter than the resource is not EOF")
    XCTAssertEqual(res.reads, 1, "a well-formed read must not trigger the binary-search clamp")
  }

  // 3. Overshooting range → clamped to the real EOF.
  func testClamp_overshootClampsToRealEOF() async throws {
    let realLength: UInt64 = 1000
    let res = FakeResource(length: realLength)
    // AVPlayer tail-probe overshoots the (overstated) length.
    let (data, eof) = try await LCPResourceLoaderDelegate.readClampedToAvailable(
      start: 0, requestedEnd: 4096
    ) { try await res.read($0) }
    XCTAssertEqual(UInt64(data.count), realLength,
                   "must clamp to the real readable length instead of failing the item")
    XCTAssertTrue(eof, "an overshoot resolves to EOF so the serve loop stops")
  }

  // 4. Range starting past EOF → clean empty EOF, not a failure.
  func testClamp_startPastEOFServesEmptyEOF() async throws {
    let res = FakeResource(length: 1000)
    let (data, eof) = try await LCPResourceLoaderDelegate.readClampedToAvailable(
      start: 2000, requestedEnd: 4096
    ) { try await res.read($0) }
    XCTAssertTrue(data.isEmpty, "nothing is readable past EOF — serve empty, don't fail")
    XCTAssertTrue(eof)
  }

  // 5. Non-bounds error → rethrown, never masked.
  func testClamp_nonBoundsErrorIsRethrown() async {
    do {
      _ = try await LCPResourceLoaderDelegate.readClampedToAvailable(
        start: 0, requestedEnd: 4096
      ) { _ in throw FakeReadError.decryptionFailed }
      XCTFail("a non-bounds error must propagate, not be clamped")
    } catch {
      XCTAssertTrue(error is FakeReadError)
      XCTAssertTrue(LCPResourceLoaderDelegate.isRangeOutOfBoundsError(FakeReadError.rangeOutOfBounds))
      XCTAssertFalse(LCPResourceLoaderDelegate.isRangeOutOfBoundsError(error))
    }
  }
}
