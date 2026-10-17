//
//  PartialArchiveStoreTests.swift
//  PalaceAudiobookToolkitTests
//
//  Core behaviour of the partial-archive store: what it reports present, what
//  it serves, what it refuses, and what survives a relaunch. The ordering
//  guarantee and the termination cases are in
//  `PartialArchiveStoreCrashSafetyTests`.
//

import Darwin
import XCTest
@testable import PalaceAudiobookToolkit

final class PartialArchiveStoreTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PartialArchiveStoreTests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    directory = nil
    try super.tearDownWithError()
  }

  /// Opens a store with a cheap durability barrier.
  ///
  /// `F_FULLFSYNC` asks the DEVICE to flush its write cache, which guards
  /// against power loss. Every guarantee these tests assert is about ordering —
  /// that the record is written after the data — and ordering is preserved by
  /// any barrier, so a plain `fsync` tests the same property. The distinction
  /// costs real time where the disk is virtualised: with the production barrier
  /// these 115 tests ran in 3.5 s locally but added over 36 s to CI, roughly
  /// doubling the suite. `testOpen_ThroughThePublicEntryPoint_UsesTheFullFlush`
  /// keeps the shipped default covered.
  private func makeStore(totalSize: UInt64 = 1000) throws -> PartialArchiveStore {
    try PartialArchiveStore(
      directory: directory,
      totalSize: totalSize,
      barrier: Self.orderingBarrier
    )
  }

  static let orderingBarrier: PartialArchiveStore.DurabilityBarrier = { descriptor, path in
    guard fsync(descriptor) == 0 else {
      throw PartialArchiveStoreError.io(code: errno, path: path)
    }
  }

  private func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
  }

  // MARK: Ask

  /// The shipped entry point and its `F_FULLFSYNC` barrier, end to end. Every
  /// other test here swaps the barrier for a cheaper one, so without this the
  /// production default would never run.
  func testOpen_ThroughThePublicEntryPoint_UsesTheFullFlush() throws {
    let payload = bytes(200, seed: 4)
    let store = try PartialArchiveStore.open(directory: directory, totalSize: 200)
    try store.write(payload, at: 0)
    XCTAssertTrue(store.isComplete())
    store.close()

    let reopened = try PartialArchiveStore.open(directory: directory, totalSize: 200)
    defer { reopened.close() }

    XCTAssertEqual(try reopened.read(0..<200), payload)
    XCTAssertTrue(reopened.isComplete())
  }


  func testCoverage_OnANewStore_ReportsEverythingMissing() throws {
    let store = try makeStore()
    defer { store.close() }

    let coverage = store.coverage(of: 0..<1000)

    XCTAssertEqual(coverage.present, [])
    XCTAssertEqual(coverage.missing, [0..<1000])
    XCTAssertFalse(coverage.isFullyPresent)
    XCTAssertEqual(store.bytesPresent(), 0)
  }

  func testCoverage_WhenAQuerySpansAGap_NamesThePresentAndMissingParts() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 200)

    let coverage = store.coverage(of: 0..<300)

    XCTAssertEqual(coverage.present, [0..<100, 200..<300])
    XCTAssertEqual(coverage.missing, [100..<200])
  }

  /// A query past the end of the archive is clipped rather than reported
  /// missing: a caller asking for "the rest of the file" would otherwise be told
  /// to fetch bytes the server does not have.
  func testCoverage_WhenTheQueryRunsPastTheArchive_ClipsToTheArchive() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    let coverage = store.coverage(of: 0..<5000)

    XCTAssertEqual(coverage.present, [0..<100])
    XCTAssertEqual(coverage.missing, [])
  }

  func testCoverage_WhenTheQueryStartsPastTheArchive_IsEmpty() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }

    let coverage = store.coverage(of: 500..<900)

    XCTAssertEqual(coverage.present, [])
    XCTAssertEqual(coverage.missing, [])
  }

  // MARK: Write

  func testWrite_ThenRead_ReturnsExactlyTheBytesWritten() throws {
    let store = try makeStore()
    defer { store.close() }
    let payload = bytes(256, seed: 7)

    try store.write(payload, at: 100)

    XCTAssertEqual(try store.read(100..<356), payload)
    XCTAssertEqual(store.bytesPresent(), 256)
  }

  func testWrite_WhenTwoWritesAreAdjacent_ReportsOneContiguousRegion() throws {
    let store = try makeStore()
    defer { store.close() }

    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 100)

    XCTAssertEqual(store.coverage(of: 0..<1000).present, [0..<200])
  }

  func testWrite_WhenWritesOverlap_ReportsTheUnionAndKeepsTheLaterBytes() throws {
    let store = try makeStore()
    defer { store.close() }

    try store.write(Data(repeating: 0xAA, count: 100), at: 0)
    try store.write(Data(repeating: 0xBB, count: 100), at: 50)

    XCTAssertEqual(store.coverage(of: 0..<1000).present, [0..<150])
    XCTAssertEqual(try store.read(0..<50), Data(repeating: 0xAA, count: 50))
    XCTAssertEqual(try store.read(50..<150), Data(repeating: 0xBB, count: 100))
  }

  func testWrite_PastTheEndOfTheArchive_IsRefusedAndRecordsNothing() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }

    XCTAssertThrowsError(try store.write(bytes(50), at: 80)) { error in
      XCTAssertEqual(
        error as? PartialArchiveStoreError,
        .rangeOutOfBounds(80..<130, totalSize: 100)
      )
    }
    XCTAssertEqual(store.bytesPresent(), 0)
  }

  func testWrite_AtTheExactEndOfTheArchive_IsAccepted() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }

    try store.write(bytes(20), at: 80)

    XCTAssertEqual(store.coverage(of: 0..<100).present, [80..<100])
  }

  func testWrite_WithNoBytes_RecordsNothing() throws {
    let store = try makeStore()
    defer { store.close() }

    let committed = try store.write(Data(), at: 50)

    XCTAssertTrue(committed.isEmpty)
    XCTAssertEqual(store.bytesPresent(), 0)
  }

  /// The free-space refusal must happen before any byte reaches the file:
  /// a chunk half-written and wholly unrecorded is recoverable, but it is
  /// cheaper never to write it.
  func testWrite_WhenTheVolumeCannotTakeTheChunk_RefusesAndRecordsNothing() throws {
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in 10 }
    )
    defer { store.close() }

    XCTAssertThrowsError(try store.write(bytes(100), at: 0)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .outOfSpace(committed: 0))
    }
    XCTAssertEqual(store.bytesPresent(), 0)
    XCTAssertEqual(store.coverage(of: 0..<1000).missing, [0..<1000])
  }

  /// Exactly enough room is enough. A refusal here would stall a download that
  /// could in fact finish, and the off-by-one is invisible except at the last
  /// chunk of a nearly-full volume.
  func testWrite_WhenTheVolumeHasExactlyEnoughRoom_Proceeds() throws {
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in 100 }
    )
    defer { store.close() }

    try store.write(bytes(100), at: 0)

    XCTAssertEqual(store.coverage(of: 0..<1000).present, [0..<100])
  }

  /// A capacity Foundation could not report means "unknown", which must not
  /// block a write. Reading it as "no space" would refuse every write on a
  /// volume whose figure is unavailable.
  func testAvailableBytes_ForAMissingOrNonPositiveCapacity_IsUnknown() {
    XCTAssertNil(PartialArchiveStore.availableBytes(forCapacity: nil))
    XCTAssertNil(PartialArchiveStore.availableBytes(forCapacity: 0))
    XCTAssertNil(PartialArchiveStore.availableBytes(forCapacity: -1))
    XCTAssertEqual(PartialArchiveStore.availableBytes(forCapacity: 4096), 4096)
  }

  /// An unknown free-space figure must not block the write — the probe is an
  /// optimisation, and the short-write path is the real authority.
  func testWrite_WhenFreeSpaceIsUnknown_ProceedsAnyway() throws {
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in nil }
    )
    defer { store.close() }

    try store.write(bytes(100), at: 0)

    XCTAssertEqual(store.coverage(of: 0..<1000).present, [0..<100])
  }

  /// The brief's hardest write case: the volume fills partway through a chunk.
  ///
  /// The bytes that reached the disk are real and must be recorded so a retry
  /// refetches only the tail; the bytes that did not must not be claimed, or the
  /// hole they left behind would be served as audio. Driven through a raw-write
  /// seam because a simulator cannot be made to run out of space on cue.
  func testWrite_WhenTheVolumeFillsPartwayThrough_RecordsOnlyWhatReachedTheDisk() throws {
    let acceptedBytes = 40
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in nil },
      rawWrite: { descriptor, pointer, count, offset in
        let allowed = min(count, max(0, acceptedBytes - Int(offset)))
        guard allowed > 0 else {
          errno = ENOSPC
          return -1
        }
        return pwrite(descriptor, pointer, allowed, offset)
      }
    )
    defer { store.close() }
    let payload = bytes(100, seed: 5)

    XCTAssertThrowsError(try store.write(payload, at: 0)) { error in
      XCTAssertEqual(
        error as? PartialArchiveStoreError,
        .outOfSpace(committed: UInt64(acceptedBytes))
      )
    }

    XCTAssertEqual(store.coverage(of: 0..<1000).present, [0..<40])
    XCTAssertEqual(store.coverage(of: 0..<100).missing, [40..<100])
    XCTAssertEqual(try store.read(0..<40), payload.prefix(40))
    XCTAssertThrowsError(try store.read(0..<100))
  }

  /// A partially written chunk survives a relaunch as the prefix it really is.
  func testReopen_AfterAPartiallyWrittenChunk_ReportsOnlyThePrefix() throws {
    let first = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in nil },
      rawWrite: { descriptor, pointer, count, offset in
        let allowed = min(count, max(0, 40 - Int(offset)))
        guard allowed > 0 else {
          errno = ENOSPC
          return -1
        }
        return pwrite(descriptor, pointer, allowed, offset)
      }
    )
    XCTAssertThrowsError(try first.write(bytes(100), at: 0))
    first.close()

    let second = try makeStore()
    defer { second.close() }

    XCTAssertEqual(second.coverage(of: 0..<1000).present, [0..<40])
  }

  /// A write that cannot place even its first byte records nothing at all.
  func testWrite_WhenNotOneByteCanBeWritten_RecordsNothing() throws {
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
    defer { store.close() }

    XCTAssertThrowsError(try store.write(bytes(100), at: 0)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .outOfSpace(committed: 0))
    }
    XCTAssertEqual(store.bytesPresent(), 0)
  }

  /// An interrupted syscall is retried, not treated as a short write: recording
  /// a prefix because a signal arrived would under-claim for no reason.
  func testWrite_WhenTheSyscallIsInterrupted_RetriesAndCommitsEverything() throws {
    let interrupted = LockIsolated(false)
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in nil },
      rawWrite: { descriptor, pointer, count, offset in
        if !interrupted.value {
          interrupted.value = true
          errno = EINTR
          return -1
        }
        return pwrite(descriptor, pointer, count, offset)
      }
    )
    defer { store.close() }
    let payload = bytes(100, seed: 2)

    try store.write(payload, at: 0)

    XCTAssertTrue(interrupted.value, "the interruption was never exercised")
    XCTAssertEqual(try store.read(0..<100), payload)
  }

  /// A zero return from the syscall is an error, not a retry: treating it as one
  /// would spin forever.
  func testWrite_WhenTheSyscallReturnsZero_FailsRatherThanSpinning() throws {
    let store = try PartialArchiveStore(
      directory: directory,
      totalSize: 1000,
      barrier: Self.orderingBarrier,
      freeSpace: { _ in nil },
      rawWrite: { _, _, _, _ in 0 }
    )
    defer { store.close() }

    XCTAssertThrowsError(try store.write(bytes(100), at: 0)) { error in
      XCTAssertEqual(
        error as? PartialArchiveStoreError,
        .io(code: EIO, path: store.archiveURL.path)
      )
    }
    XCTAssertEqual(store.bytesPresent(), 0)
  }

  // MARK: Read

  /// Whole-or-nothing. A hole in the archive reads back as zeros of exactly the
  /// right length (see `SparseArchiveHoleTests`), so a short or zero-filled
  /// result is indistinguishable from content at the call site. The gap has to
  /// come back as an error naming it.
  func testRead_WhenTheRangeSpansAGap_ThrowsNamingTheGap() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 200)

    XCTAssertThrowsError(try store.read(0..<300)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .notPresent(missing: [100..<200]))
    }
  }

  func testRead_WhenTheRangeIsEntirelyInAGap_ThrowsNamingTheWholeRange() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    XCTAssertThrowsError(try store.read(500..<600)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .notPresent(missing: [500..<600]))
    }
  }

  func testRead_AtTheExactEndOfTheArchive_ReturnsTheFinalBytes() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }
    let payload = bytes(100, seed: 3)
    try store.write(payload, at: 0)

    XCTAssertEqual(try store.read(99..<100), payload.suffix(1))
    XCTAssertEqual(try store.read(0..<100), payload)
  }

  func testRead_PastTheEndOfTheArchive_IsRefused() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    XCTAssertThrowsError(try store.read(50..<200)) { error in
      XCTAssertEqual(
        error as? PartialArchiveStoreError,
        .rangeOutOfBounds(50..<200, totalSize: 100)
      )
    }
  }

  func testRead_OfAnEmptyRange_ReturnsNoBytes() throws {
    let store = try makeStore()
    defer { store.close() }

    XCTAssertEqual(try store.read(50..<50), Data())
  }

  func testReadContiguous_ServesUpToTheGapAndNoFurther() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(Data(repeating: 0xCC, count: 100), at: 0)
    try store.write(Data(repeating: 0xDD, count: 100), at: 200)

    let served = try store.readContiguous(from: 40, maxLength: 500)

    XCTAssertEqual(served, Data(repeating: 0xCC, count: 60))
  }

  func testReadContiguous_FromInsideAGap_ReturnsNoBytes() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    XCTAssertEqual(try store.readContiguous(from: 500, maxLength: 100), Data())
  }

  func testReadContiguous_AtTheExactEndOfTheArchive_ReturnsNoBytes() throws {
    let store = try makeStore(totalSize: 100)
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    XCTAssertEqual(try store.readContiguous(from: 100, maxLength: 10), Data())
    XCTAssertEqual(try store.readContiguous(from: 99, maxLength: 10).count, 1)
  }

  func testReadContiguous_WithNoLengthToServe_ReturnsNoBytes() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    XCTAssertEqual(try store.readContiguous(from: 0, maxLength: 0), Data())
  }

  func testReadContiguous_HonoursTheLengthCap() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(500), at: 0)

    XCTAssertEqual(try store.readContiguous(from: 0, maxLength: 10).count, 10)
  }

  // MARK: Completeness

  func testIsComplete_WhenEveryByteIsWritten_IsTrue() throws {
    let store = try makeStore(totalSize: 300)
    defer { store.close() }

    try store.write(bytes(100), at: 0)
    try store.write(bytes(100), at: 200)
    XCTAssertFalse(store.isComplete())

    try store.write(bytes(100), at: 100)

    XCTAssertTrue(store.isComplete())
  }

  /// The check this replaces was file existence, and the file exists from the
  /// first byte written — at its full length, because it is created sparse. So
  /// one missing byte in the middle has to read as incomplete.
  func testIsComplete_WhenASingleByteIsMissing_IsFalse() throws {
    let store = try makeStore(totalSize: 300)
    defer { store.close() }

    try store.write(bytes(150), at: 0)
    try store.write(bytes(149), at: 151)

    XCTAssertFalse(store.isComplete())
    XCTAssertEqual(store.coverage(of: 0..<300).missing, [150..<151])
  }

  func testIsComplete_OnANewStore_IsFalse() throws {
    let store = try makeStore()
    defer { store.close() }

    XCTAssertFalse(store.isComplete())
  }

  // MARK: Decryptable coverage

  /// The window CBC needs is wider than the plaintext: a block of lead-in for
  /// the chain, and a block past the one holding the last byte.
  func testDecryptableWindow_CoversTheChainingBlocksAroundThePlaintext() {
    XCTAssertEqual(
      PartialArchiveStore.decryptableWindow(for: 20..<40, totalSize: 1000),
      16..<64
    )
  }

  /// A window for a range that begins at or past the end of the archive is
  /// empty, not a window over the final blocks. Anything else would have a
  /// reader fetch bytes the origin does not have.
  func testDecryptableWindow_ForARangeAtOrPastTheEnd_IsEmpty() {
    XCTAssertTrue(PartialArchiveStore.decryptableWindow(for: 100..<101, totalSize: 100).isEmpty)
    XCTAssertTrue(PartialArchiveStore.decryptableWindow(for: 200..<300, totalSize: 100).isEmpty)
    XCTAssertTrue(PartialArchiveStore.decryptableWindow(for: 50..<50, totalSize: 100).isEmpty)
  }

  func testDecryptableWindow_IsClippedToTheArchive() {
    XCTAssertEqual(
      PartialArchiveStore.decryptableWindow(for: 90..<100, totalSize: 100),
      80..<100
    )
  }

  /// A write that ends mid-block leaves that block undecryptable, so the
  /// aligned view must report the partial block missing even though the bytes
  /// for part of it are on disk.
  func testDecryptableCoverage_WhenAWriteEndsMidBlock_ReportsThePartialBlockMissing() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)

    let coverage = store.decryptableCoverage(of: 0..<100)

    XCTAssertEqual(coverage.present, [0..<96])
    XCTAssertEqual(coverage.missing, [96..<128])
  }

  /// And the byte-exact record still knows about those bytes: once the
  /// neighbouring write completes the block, nothing refetches them.
  func testDecryptableCoverage_AfterTheNeighbouringWriteLands_ReportsTheBlockPresent() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 0)
    try store.write(bytes(28), at: 100)

    XCTAssertEqual(store.decryptableCoverage(of: 0..<100).missing, [])
    XCTAssertEqual(store.coverage(of: 0..<128).present, [0..<128])
  }

  func testDecryptableCoverage_NeverReportsPresentWhatTheExactRecordLacks() throws {
    let store = try makeStore()
    defer { store.close() }
    try store.write(bytes(100), at: 5)
    try store.write(bytes(70), at: 300)

    for range in store.decryptableCoverage(of: 0..<400).present {
      XCTAssertEqual(
        store.coverage(of: range).missing, [],
        "aligned view claimed \(range), which the exact record does not hold"
      )
    }
  }

  // MARK: Persistence

  func testReopen_AfterWrites_ReportsTheSameRangesPresent() throws {
    let first = try makeStore()
    try first.write(bytes(100), at: 0)
    try first.write(bytes(100), at: 500)
    first.close()

    let second = try makeStore()
    defer { second.close() }

    XCTAssertEqual(second.coverage(of: 0..<1000).present, [0..<100, 500..<600])
    XCTAssertEqual(second.bytesPresent(), 200)
  }

  func testReopen_AfterWrites_StillServesTheBytes() throws {
    let payload = bytes(200, seed: 11)
    let first = try makeStore()
    try first.write(payload, at: 300)
    first.close()

    let second = try makeStore()
    defer { second.close() }

    XCTAssertEqual(try second.read(300..<500), payload)
  }

  func testReopen_WhenTheArchiveIsComplete_StillReportsComplete() throws {
    let first = try makeStore(totalSize: 200)
    try first.write(bytes(200), at: 0)
    first.close()

    let second = try makeStore(totalSize: 200)
    defer { second.close() }

    XCTAssertTrue(second.isComplete())
  }

  /// A total size that disagrees with the one the archive was created for means
  /// these bytes belong to a different object. Reinterpreting them would make
  /// every offset in the record wrong, so the store refuses and leaves the
  /// decision to the caller.
  func testOpen_WhenTheTotalSizeDisagreesWithTheRecord_IsRefused() throws {
    let first = try makeStore(totalSize: 1000)
    try first.write(bytes(100), at: 0)
    first.close()

    XCTAssertThrowsError(try makeStore(totalSize: 2000)) { error in
      XCTAssertEqual(
        error as? PartialArchiveStoreError,
        .totalSizeMismatch(recorded: 1000, requested: 2000)
      )
    }
  }

  /// An `off_t` is signed, so a size above `Int64.max` would trap on
  /// conversion rather than be refused. A server's Content-Length is input.
  func testOpen_WithATotalSizeTooLargeToAddress_IsRefused() throws {
    XCTAssertThrowsError(try makeStore(totalSize: UInt64(Int64.max) + 1)) { error in
      XCTAssertEqual(
        error as? PartialArchiveStoreError,
        .invalidTotalSize(UInt64(Int64.max) + 1)
      )
    }
  }

  func testOpen_WithAZeroTotalSize_IsRefused() throws {
    XCTAssertThrowsError(try makeStore(totalSize: 0)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .invalidTotalSize(0))
    }
  }

  /// Nothing may hold the lock after a refused open, or a legitimate reopen at
  /// the right size would fail with `.alreadyOpen` forever.
  func testOpen_AfterARefusedOpen_StillAllowsAValidOne() throws {
    let first = try makeStore(totalSize: 1000)
    try first.write(bytes(100), at: 0)
    first.close()
    XCTAssertThrowsError(try makeStore(totalSize: 2000))

    let reopened = try makeStore(totalSize: 1000)
    defer { reopened.close() }

    XCTAssertEqual(reopened.coverage(of: 0..<1000).present, [0..<100])
  }

  // MARK: Two writers

  func testOpen_WhileAnotherStoreHoldsTheDirectory_IsRefused() throws {
    let first = try makeStore()
    defer { first.close() }

    XCTAssertThrowsError(try makeStore()) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .alreadyOpen(directory))
    }
  }

  func testOpen_AfterTheFirstStoreCloses_Succeeds() throws {
    let first = try makeStore()
    try first.write(bytes(100), at: 0)
    first.close()

    let second = try makeStore()
    defer { second.close() }

    XCTAssertEqual(second.coverage(of: 0..<1000).present, [0..<100])
  }

  // MARK: Lifecycle

  func testDelete_RemovesTheArchiveAndItsRecord() throws {
    let store = try makeStore()
    try store.write(bytes(100), at: 0)
    let archive = store.archiveURL

    try store.delete()

    XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertEqual(store.bytesPresent(), 0)
  }

  func testDelete_ThenReopen_StartsEmpty() throws {
    let first = try makeStore()
    try first.write(bytes(100), at: 0)
    try first.delete()

    let second = try makeStore()
    defer { second.close() }

    XCTAssertEqual(second.coverage(of: 0..<1000).missing, [0..<1000])
    XCTAssertFalse(second.isComplete())
  }

  /// A returned loan deletes the content; a second delete on the way out of the
  /// same flow must not be an error.
  func testDelete_WhenAlreadyDeleted_Succeeds() throws {
    let store = try makeStore()
    try store.delete()

    XCTAssertNoThrow(try store.delete())
  }

  func testDelete_AfterClose_StillRemovesTheFiles() throws {
    let store = try makeStore()
    try store.write(bytes(100), at: 0)
    store.close()

    try store.delete()

    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testWrite_AfterClose_IsRefused() throws {
    let store = try makeStore()
    store.close()

    XCTAssertThrowsError(try store.write(bytes(10), at: 0)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .closed)
    }
  }

  func testRead_AfterClose_IsRefused() throws {
    let store = try makeStore()
    try store.write(bytes(100), at: 0)
    store.close()

    XCTAssertThrowsError(try store.read(0..<100)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .closed)
    }
    XCTAssertThrowsError(try store.readContiguous(from: 0, maxLength: 10)) { error in
      XCTAssertEqual(error as? PartialArchiveStoreError, .closed)
    }
  }

  func testClose_WhenCalledTwice_Succeeds() throws {
    let store = try makeStore()

    store.close()

    XCTAssertNoThrow(store.close())
  }

  // MARK: Concurrency

  /// Writes from several threads must all be recorded and none may be lost or
  /// interleaved into a corrupt record: the fill and the serving reads really do
  /// arrive on different threads.
  func testWrite_FromManyThreadsAtOnce_RecordsEveryRange() throws {
    let store = try makeStore(totalSize: 64 * 100)
    defer { store.close() }

    DispatchQueue.concurrentPerform(iterations: 64) { index in
      do {
        try store.write(Data(repeating: UInt8(index), count: 100), at: UInt64(index) * 100)
      } catch {
        XCTFail("write \(index) failed: \(error)")
      }
    }

    XCTAssertTrue(store.isComplete())
    XCTAssertEqual(store.coverage(of: 0..<6400).present, [0..<6400])
    for index in 0..<64 {
      XCTAssertEqual(
        try store.read(UInt64(index) * 100..<UInt64(index + 1) * 100),
        Data(repeating: UInt8(index), count: 100)
      )
    }
  }
}
