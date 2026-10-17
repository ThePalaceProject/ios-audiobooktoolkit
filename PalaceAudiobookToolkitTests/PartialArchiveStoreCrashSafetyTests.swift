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

  /// A plain `fsync` rather than `F_FULLFSYNC`. These tests simulate the
  /// process being KILLED, for which what matters is that the record is written
  /// after the data — ordering, which any barrier preserves. A device cache
  /// flush guards against power loss instead, and costs real time where the
  /// disk is virtualised. The kill-window test below still drives the shipped
  /// barrier.
  static let orderingBarrier: PartialArchiveStore.DurabilityBarrier = { descriptor, path in
    guard fsync(descriptor) == 0 else {
      throw PartialArchiveStoreError.io(code: errno, path: path)
    }
  }

  private func openStore(totalSize: UInt64 = 1000) throws -> PartialArchiveStore {
    try PartialArchiveStore(
      directory: directory,
      totalSize: totalSize,
      barrier: Self.orderingBarrier
    )
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

    let reopened = try openStore()
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

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<200])
    XCTAssertEqual(reopened.bytesPresent(), 200)
  }

  // MARK: A damaged record file

  /// A kill during the record append leaves a line with no terminating newline.
  /// A fragment is not a record.
  func testReopen_WhenTheRecordFileEndsInAnUnterminatedLine_DropsThatLineOnly() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 500)
    store.close()

    var journal = try Data(contentsOf: journalURL)
    journal.append(contentsOf: Array("700 800 99".utf8))  // no newline: torn append
    try journal.write(to: journalURL)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100, 500..<600])
  }

  /// A torn write can land a newline and still leave the bytes wrong, which is
  /// why each record carries a checksum rather than relying on the newline.
  func testReopen_WhenARecordsChecksumDoesNotMatch_StopsAtThatRecord() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    store.close()

    var journal = try String(contentsOf: journalURL, encoding: .utf8)
    journal += "500 600 12345\n"  // well-formed, wrong checksum
    try journal.write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  /// Records after a damaged one are discarded too, not skipped: in an
  /// append-only file a damaged record means the tail cannot be vouched for,
  /// and under-claiming is the only safe way to be wrong.
  func testReopen_WhenADamagedRecordHasIntactOnesAfterIt_DiscardsTheTail() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    store.close()

    var lines = try String(contentsOf: journalURL, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    lines.append("200 300 1")  // damaged
    lines.append("400 500 \(PartialArchiveStore.crc32(Array("400 500".utf8)))")  // intact
    try (lines.joined(separator: "\n") + "\n")
      .write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  /// A record naming bytes past the end of the archive is damage, not something
  /// to clamp: `write` bounds-checks, so no healthy run can produce one, and
  /// accepting it would have the record describe bytes that cannot exist.
  func testReopen_WhenARecordNamesBytesPastTheArchive_StopsAtThatRecord() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    store.close()

    let body = "900 2000"
    var journal = try String(contentsOf: journalURL, encoding: .utf8)
    journal += "\(body) \(PartialArchiveStore.crc32(Array(body.utf8)))\n"
    try journal.write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  func testReopen_WhenTheRecordFileIsGarbage_ReportsNothingPresent() throws {
    let store = try openStore()
    try store.write(bytes(1000), at: 0)
    store.close()
    let healthy = try openStore()
    XCTAssertTrue(healthy.isComplete(), "the record was not healthy before being damaged")
    healthy.close()

    try Data(repeating: 0x7F, count: 4096).write(to: journalURL)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).missing, [0..<1000])
    XCTAssertFalse(reopened.isComplete())
  }

  func testReopen_WhenTheRecordFileIsEmpty_ReportsNothingPresent() throws {
    let store = try openStore()
    try store.write(bytes(500), at: 0)
    store.close()

    try Data().write(to: journalURL)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.bytesPresent(), 0)
  }

  func testReopen_WhenOnlyTheHeaderSurvived_ReportsNothingPresent() throws {
    let store = try openStore()
    try store.write(bytes(500), at: 0)
    store.close()

    try "\(PartialArchiveStore.journalMagic) 1000\n"
      .write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.bytesPresent(), 0)
  }

  /// The checksum has to be a known algorithm, not merely a self-consistent
  /// one. Every other test computes its expected checksum with the same
  /// function it is checking, so a wrong implementation would round-trip
  /// perfectly and detect nothing. This is the standard CRC-32 check value.
  func testChecksum_MatchesTheStandardCRC32CheckValue() {
    XCTAssertEqual(PartialArchiveStore.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    XCTAssertEqual(PartialArchiveStore.crc32([]), 0)
  }

  /// A record naming an empty range is damage, not a harmless no-op: `write`
  /// never emits one, and accepting it would let the loader carry on past a
  /// record it cannot vouch for.
  func testReopen_WhenARecordNamesAnEmptyRange_StopsAtThatRecord() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    store.close()

    var journal = try String(contentsOf: journalURL, encoding: .utf8)
    for body in ["500 500", "600 700"] {
      journal += "\(body) \(PartialArchiveStore.crc32(Array(body.utf8)))\n"
    }
    try journal.write(to: journalURL, atomically: true, encoding: .utf8)

    let reopened = try openStore()
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  /// A healthy record file is left exactly as it is. Rewriting it on every
  /// launch would mean a rename of the one file the store's guarantee rests on,
  /// repeatedly, for no reason.
  func testReopen_WhenTheRecordIsHealthy_LeavesItByteForByte() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 500)
    store.close()
    let before = try Data(contentsOf: journalURL)

    let reopened = try openStore()
    let after = try Data(contentsOf: journalURL)
    reopened.close()

    XCTAssertEqual(after, before)
  }

  /// And a damaged one IS rewritten, so the damage is not re-read at every
  /// launch thereafter.
  func testReopen_WhenTheRecordWasDamaged_RewritesItClean() throws {
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    store.close()

    var journal = try Data(contentsOf: journalURL)
    journal.append(contentsOf: Array("600 700".utf8))  // torn, unterminated
    try journal.write(to: journalURL)

    let first = try openStore()
    first.close()
    let rewritten = try Data(contentsOf: journalURL)

    XCTAssertFalse(
      String(decoding: rewritten, as: UTF8.self).hasSuffix("600 700"),
      "the torn fragment was left in the record file"
    )
    let second = try openStore()
    defer { second.close() }
    XCTAssertEqual(second.coverage(of: 0..<1000).present, [0..<100])
  }

  /// A failed write that moved no bytes must add no record at all — not a
  /// zero-length one, which a later load has to treat as damage and which would
  /// then discard every record appended after it.
  func testWrite_WhenItMovesNoBytes_AppendsNoRecord() throws {
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in nil },
      rawWrite: { _, _, _, _ in
        errno = ENOSPC
        return -1
      }
    )
    XCTAssertThrowsError(try store.write(bytes(100), at: 0))
    store.close()

    let lines = try String(contentsOf: journalURL, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)

    XCTAssertEqual(lines.count, 1, "expected the header alone, got \(lines)")
    XCTAssertTrue(lines[0].hasPrefix(PartialArchiveStore.journalMagic))
  }

  // MARK: Every truncation point

  /// The property, not one instance of it: for every single prefix of a healthy
  /// record file — which is every point a kill during an append can leave it at
  /// — reopening claims a subset of what was really written, and claims the
  /// archive complete only when the record is whole.
  func testReopen_AtEveryTruncationPointOfTheRecordFile_NeverOverClaims() throws {
    let written: [Range<UInt64>] = [0..<100, 100..<200, 400..<500, 900..<1000]
    let store = try openStore()
    for range in written {
      try store.write(bytes(range.count), at: range.lowerBound)
    }
    store.close()
    let healthy = try Data(contentsOf: journalURL)
    let truth = ByteRangeSet(written)

    for length in 0...healthy.count {
      try healthy.prefix(length).write(to: journalURL)

      let reopened = try openStore()
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
    let store = try openStore()
    try store.write(bytes(100), at: 0)
    store.close()

    // Write past the recorded region behind the store's back, as an interrupted
    // transfer would have left it.
    let descriptor = Darwin.open(archiveURL.path, O_WRONLY)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    let smuggled = Array(bytes(100, seed: 42))
    XCTAssertEqual(pwrite(descriptor, smuggled, smuggled.count, 500), 100)
    close(descriptor)

    let reopened = try openStore()
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
    let store = try openStore(totalSize: 4096)
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
    let cheapBarrier = Self.orderingBarrier
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
