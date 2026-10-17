//
//  SparseArchiveHoleTests.swift
//  PalaceAudiobookToolkitTests
//
//  Why `PartialArchiveStore` consults its record before every read and never
//  validates bytes after reading them. These tests touch no Palace code: they
//  characterise the filesystem the store is built on.
//

import Darwin
import XCTest

final class SparseArchiveHoleTests: XCTestCase {

  private var fileURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("SparseArchiveHoleTests-\(UUID().uuidString).bin")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: fileURL)
    fileURL = nil
    try super.tearDownWithError()
  }

  /// The failure mode this component exists to make impossible.
  ///
  /// A hole in the archive comes back as zeros — the right NUMBER of wrong
  /// bytes. A short-read guard cannot fire, `st_size` reports the full length,
  /// the AES-CBC payload is unauthenticated, and no read path checks a CRC. So
  /// nothing between the file and the patron's ears can tell a hole from
  /// content: either the record is consulted first and believed, or garbage is
  /// served from a file that looks healthy.
  func testReadAcrossAHole_ReturnsZerosOfTheRightLengthWithNoError() throws {
    let descriptor = Darwin.open(fileURL.path, O_RDWR | O_CREAT, 0o644)
    XCTAssertGreaterThanOrEqual(descriptor, 0, "could not create the file")
    defer { close(descriptor) }

    // A 1 MB archive with content only in its last 64 bytes.
    let length: off_t = 1 << 20
    XCTAssertEqual(ftruncate(descriptor, length), 0)
    let tail = [UInt8](repeating: 0xAB, count: 64)
    XCTAssertEqual(pwrite(descriptor, tail, tail.count, length - 64), 64)

    // Read across the hole and into the content.
    var buffer = [UInt8](repeating: 0xFF, count: 128)
    let read = pread(descriptor, &buffer, 128, length - 128)

    XCTAssertEqual(read, 128, "the read was not short — the hole supplied bytes")
    XCTAssertEqual(
      Array(buffer.prefix(64)), [UInt8](repeating: 0, count: 64),
      "the hole read back as something other than zeros"
    )
    XCTAssertEqual(Array(buffer.suffix(64)), tail)

    var status = stat()
    XCTAssertEqual(fstat(descriptor, &status), 0)
    XCTAssertEqual(
      status.st_size, length,
      "size reports the full length although all but 64 bytes were never written"
    )
  }

  /// `ftruncate` to the final length is cheap at archive scale, which is why
  /// the store does it at creation — but only at archive scale. A 1 MB file was
  /// measured fully allocated on APFS, so the free-space question has to be
  /// asked per fill rather than answered once by this allocation.
  func testTruncateToArchiveLength_AllocatesFarLessThanItsLogicalSize() throws {
    let descriptor = Darwin.open(fileURL.path, O_RDWR | O_CREAT, 0o644)
    XCTAssertGreaterThanOrEqual(descriptor, 0, "could not create the file")
    defer { close(descriptor) }

    let length: off_t = 100 << 20
    XCTAssertEqual(ftruncate(descriptor, length), 0)

    var status = stat()
    XCTAssertEqual(fstat(descriptor, &status), 0)
    XCTAssertEqual(status.st_size, length)
    XCTAssertLessThan(
      Int64(status.st_blocks) * 512, length / 100,
      "a 100 MB extent allocated more than 1% of its logical size"
    )
  }
}
