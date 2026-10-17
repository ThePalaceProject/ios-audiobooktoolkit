//
//  PartialArchiveStoreCrashSafetyTests.swift
//  PalaceAudiobookToolkitTests
//
//  The store's one critical promise: the record never names a byte that is not
//  durably on disk. The app is killed in the background routinely, so every
//  test here reproduces an on-disk state a kill can leave and asserts the store
//  comes back under-claiming rather than over-claiming.
//

import Darwin
import XCTest
@testable import PalaceAudiobookToolkit

final class PartialArchiveStoreCrashSafetyTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PartialArchiveCrashTests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    directory = nil
    try super.tearDownWithError()
  }

  private var journalURL: URL {
    directory.appendingPathComponent(PartialArchiveStore.journalFileName)
  }

  private var archiveURL: URL {
    directory.appendingPathComponent(PartialArchiveStore.archiveFileName)
  }

  private func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
  }

  /// Reads the archive file directly, bypassing the store, to show what the
  /// file holds independently of what the record claims.
  private func rawArchiveBytes(_ range: Range<UInt64>) -> Data {
    let descriptor = Darwin.open(archiveURL.path, O_RDONLY)
    XCTAssertGreaterThanOrEqual(descriptor, 0, "the archive file is absent")
    guard descriptor >= 0 else { return Data() }
    defer { close(descriptor) }
    var buffer = [UInt8](repeating: 0, count: range.count)
    let read = pread(descriptor, &buffer, range.count, off_t(range.lowerBound))
    XCTAssertEqual(read, range.count, "short raw read")
    return Data(buffer)
  }

  // MARK: Killed between the data flush and the record

  /// The whole window in which this type could lie: the bytes are durable, and
  /// the process dies before the record names them.
  ///
  /// Reproduced through the real write path — the barrier performs the real
  /// flush and then throws, so the file and the journal are left in exactly the
  /// state a kill at that instant produces — rather than by reasoning about the
  /// ordering.
  func testReopen_WhenKilledAfterTheDataFlushAndBeforeTheRecord_ReportsTheRangeMissing() throws {
    let payload = bytes(256, seed: 9)
    let archivePath = archiveURL.path
    let killAfterDataFlush: PartialArchiveStore.DurabilityBarrier = { descriptor, path in
      try PartialArchiveStore.fullFlushBarrier(descriptor, path)
      if path == archivePath {
        throw PartialArchiveStoreError.io(code: EINTR, path: path)
      }
    }

    let dying = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: killAfterDataFlush
    )
    try? dying.write(bytes(100), at: 0)  // never recorded, by construction
    dying.close()

    // The kill window was real: those bytes ARE on disk.
    XCTAssertEqual(rawArchiveBytes(0..<100), bytes(100))

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).missing, [0..<1000])
    XCTAssertEqual(reopened.bytesPresent(), 0)
    XCTAssertFalse(reopened.isComplete())
    XCTAssertThrowsError(try reopened.read(0..<100)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .notPresent(missing: [0..<100]))
    }

    // And the range is refetchable: writing it again records it normally.
    try reopened.write(payload, at: 0)
    XCTAssertEqual(try reopened.read(0..<256), payload)
  }

  /// The same kill, with earlier writes already recorded: those must survive.
  /// Losing the whole download because the last chunk was interrupted would be
  /// a second bug on top of the one being fixed.
  func testReopen_WhenKilledMidWrite_KeepsEveryEarlierRecordedRange() throws {
    let archivePath = archiveURL.path
    let dieNow = LockIsolated(false)
    let barrier: PartialArchiveStore.DurabilityBarrier = { descriptor, path in
      try PartialArchiveStore.fullFlushBarrier(descriptor, path)
      if dieNow.value, path == archivePath {
        throw PartialArchiveStoreError.io(code: EINTR, path: path)
      }
    }

    let dying = try PartialArchiveStore(directory: directory, totalSize: 1000, barrier: barrier)
    try dying.write(bytes(100), at: 0)
    try dying.write(bytes(100), at: 100)
    dieNow.value = true
    try? dying.write(bytes(100), at: 200)
    dying.close()

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<200])
    XCTAssertEqual(reopened.bytesPresent(), 200)
  }

  // MARK: A damaged record file

  /// A kill during the record append leaves a line with no terminating newline.
  /// A fragment is not a record.
  func testReopen_WhenTheRecordFileEndsInAnUnterminatedLine_DropsThatLineOnly() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 500)
    store.close()

    var journal = try Data(contentsOf: journalURL)
    journal.append(contentsOf: Array("700 800 99".utf8))  // no newline: torn append
    try journal.write(to: journalURL)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100, 500..<600])
  }

  /// A torn write can land a newline and still leave the bytes wrong, which is
  /// why each record carries a checksum rather than relying on the newline.
  func testReopen_WhenARecordsChecksumDoesNotMatch_StopsAtThatRecord() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(100), at: 0)
    store.close()

    var journal = try String(contentsOf: journalURL, encoding: .utf8)
    journal += "500 600 12345\n"  // well-formed, wrong checksum
    try journal.write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  /// Records after a damaged one are discarded too, not skipped: in an
  /// append-only file a damaged record means the tail cannot be vouched for,
  /// and under-claiming is the only safe way to be wrong.
  func testReopen_WhenADamagedRecordHasIntactOnesAfterIt_DiscardsTheTail() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(100), at: 0)
    store.close()

    var lines = try String(contentsOf: journalURL, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    lines.append("200 300 1")  // damaged
    lines.append("400 500 \(PartialArchiveStore.crc32(Array("400 500".utf8)))")  // intact
    try (lines.joined(separator: "\n") + "\n")
      .write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  func testReopen_WhenTheRecordFileIsGarbage_ReportsNothingPresent() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(1000), at: 0)
    store.close()
    let healthy = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    XCTAssertTrue(healthy.isComplete(), "the record was not healthy before being damaged")
    healthy.close()

    try Data(repeating: 0x7F, count: 4096).write(to: journalURL)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).missing, [0..<1000])
    XCTAssertFalse(reopened.isComplete())
  }

  func testReopen_WhenTheRecordFileIsEmpty_ReportsNothingPresent() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(500), at: 0)
    store.close()

    try Data().write(to: journalURL)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.bytesPresent(), 0)
  }

  func testReopen_WhenOnlyTheHeaderSurvived_ReportsNothingPresent() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(500), at: 0)
    store.close()

    try "\(PartialArchiveStore.journalMagic) 1000\n"
      .write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.bytesPresent(), 0)
  }

  // MARK: Every truncation point

  /// The property, not one instance of it: for every single prefix of a healthy
  /// record file — which is every point a kill during an append can leave it at
  /// — reopening claims a subset of what was really written, and claims the
  /// archive complete only when the record is whole.
  func testReopen_AtEveryTruncationPointOfTheRecordFile_NeverOverClaims() throws {
    let written: [Range<UInt64>] = [0..<100, 100..<200, 400..<500, 900..<1000]
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    for range in written {
      try store.write(bytes(range.count), at: range.lowerBound)
    }
    store.close()
    let healthy = try Data(contentsOf: journalURL)
    let truth = ByteRangeSet(written)

    for length in 0...healthy.count {
      try healthy.prefix(length).write(to: journalURL)

      let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
      let present = reopened.coverage(of: 0..<1000).present
      reopened.close()

      for range in present {
        XCTAssertTrue(
          truth.contains(range),
          "truncated to \(length) bytes, claimed \(range), which was never written"
        )
      }
      XCTAssertFalse(
        ByteRangeSet(present).covers(totalSize: 1000),
        "truncated to \(length) bytes and still claimed the archive complete"
      )
    }
  }

  // MARK: A sparse archive the record disagrees with

  /// The state that makes the record the only authority: bytes on disk that the
  /// record does not name must not be served, and an archive whose file is full
  /// length must not read as complete.
  func testStore_WhenTheFileHoldsBytesTheRecordDoesNotName_RefusesToServeThem() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    try store.write(bytes(100), at: 0)
    store.close()

    // Write past the recorded region behind the store's back, as an interrupted
    // transfer would have left it.
    let descriptor = Darwin.open(archiveURL.path, O_WRONLY)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    let smuggled = Array(bytes(100, seed: 42))
    XCTAssertEqual(pwrite(descriptor, smuggled, smuggled.count, 500), 100)
    close(descriptor)

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
    XCTAssertThrowsError(try reopened.read(500..<600))
    XCTAssertEqual(try reopened.readContiguous(from: 500, maxLength: 100), Data())
    XCTAssertFalse(reopened.isComplete())
  }

  /// `ftruncate` gives the file its full length at creation, so file size says
  /// nothing about what is present. The check this store replaces was exactly a
  /// size-or-existence check.
  func testArchiveFile_OnANewStore_IsAlreadyFullLengthAndEmptyOfContent() throws {
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 4096)
    defer { store.close() }

    let size = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int

    XCTAssertEqual(size, 4096)
    XCTAssertEqual(store.bytesPresent(), 0)
    XCTAssertFalse(store.isComplete())
  }

  // MARK: Record growth

  /// The record file is rewritten from the merged set once it has accumulated
  /// more records than intervals, so an archive filled in small pieces does not
  /// leave an unbounded file behind. A plain `fsync` barrier here: this is about
  /// file size, and a full flush per write would make the test minutes long.
  func testReopen_WhenTheRecordHasManyMoreRecordsThanIntervals_CompactsIt() throws {
    let cheapBarrier: PartialArchiveStore.DurabilityBarrier = { descriptor, path in
      guard fsync(descriptor) == 0 else {
        throw PartialArchiveStoreError.io(code: errno, path: path)
      }
    }
    let records = PartialArchiveStore.compactionThreshold + 10
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: UInt64(records) * 4,
      barrier: cheapBarrier
    )
    for index in 0..<records {
      try store.write(bytes(4), at: UInt64(index) * 4)
    }
    let sizeBefore = try Data(contentsOf: journalURL).count
    store.close()

    let reopened = try PartialArchiveStore(
      directory: directory,
      totalSize: UInt64(records) * 4,
      barrier: cheapBarrier
    )
    defer { reopened.close() }
    let sizeAfter = try Data(contentsOf: journalURL).count

    XCTAssertTrue(reopened.isComplete())
    XCTAssertLessThan(sizeAfter, sizeBefore / 10)
  }
}
