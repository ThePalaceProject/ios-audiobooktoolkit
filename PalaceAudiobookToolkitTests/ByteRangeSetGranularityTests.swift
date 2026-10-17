//
//  ByteRangeSetGranularityTests.swift
//  PalaceAudiobookToolkitTests
//
//  Evidence for the representation `PartialArchiveStore` uses: merged
//  contiguous intervals rather than a block map. These tests model the two
//  candidates against the access patterns the archive actually sees and measure
//  the difference, so the choice can be revisited against numbers instead of
//  intuition. They allocate nothing and touch no disk.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class ByteRangeSetGranularityTests: XCTestCase {

  private static let archiveSize: UInt64 = 700 << 20
  /// What one range request fetches: the per-track buffer the streaming loader
  /// already uses.
  private static let fillChunk: UInt64 = 6 << 20
  /// What one `URLSession` delivery hands over. Deliberately not a power of two
  /// and not a multiple of any block size: the transport chooses this, so a
  /// writer cannot make it aligned.
  private static let deliveryChunk: UInt64 = 48_000

  /// A block map that only marks a block when it holds every byte of it — the
  /// only way such a map can avoid claiming a byte it does not have.
  private struct HonestBlockMap {
    let blockSize: UInt64
    private var blocks: Set<UInt64> = []

    init(blockSize: UInt64) {
      self.blockSize = blockSize
    }

    mutating func insert(_ range: Range<UInt64>) {
      let first = range.lowerBound.roundedUpToMultiple(of: blockSize) / blockSize
      let lastExclusive = range.upperBound.roundedDownToMultiple(of: blockSize) / blockSize
      guard first < lastExclusive else { return }
      for block in first..<lastExclusive { blocks.insert(block) }
    }

    func contains(_ offset: UInt64) -> Bool { blocks.contains(offset / blockSize) }
    var byteCount: UInt64 { UInt64(blocks.count) * blockSize }
  }

  // MARK: Interval count under the real access patterns

  /// A sequential fill converges on one interval, whatever the chunk size, so
  /// the record for a finished book is a single line. This is the whole reason
  /// the completeness check can be one comparison.
  func testIntervalCount_UnderASequentialFill_StaysAtOne() {
    var set = ByteRangeSet()
    var offset: UInt64 = 0
    var maximumIntervals = 0

    while offset < Self.archiveSize {
      let end = min(offset + Self.deliveryChunk, Self.archiveSize)
      set.insert(offset..<end)
      maximumIntervals = max(maximumIntervals, set.ranges.count)
      offset = end
    }

    XCTAssertEqual(maximumIntervals, 1)
    XCTAssertTrue(set.covers(totalSize: Self.archiveSize))
  }

  /// The pattern that could in principle break intervals: the loader's prefetch
  /// window reads several widely separated tracks while the background fill
  /// advances from the front. The interval count is bounded by the number of
  /// reading fronts, not by the number of writes — 8 reads plus a fill front
  /// over 15,000 writes stays in single figures.
  func testIntervalCount_WithEightReadFrontsPlusASequentialFill_StaysBoundedByTheFronts() {
    let fronts = 8
    var set = ByteRangeSet()
    var readHeads = (0..<fronts).map { UInt64($0 + 1) * (Self.archiveSize / UInt64(fronts + 2)) }
    var fillHead: UInt64 = 0
    var maximumIntervals = 0

    while fillHead < Self.archiveSize {
      for index in readHeads.indices {
        let end = min(readHeads[index] + Self.deliveryChunk, Self.archiveSize)
        set.insert(readHeads[index]..<end)
        readHeads[index] = end
      }
      let fillEnd = min(fillHead + Self.deliveryChunk, Self.archiveSize)
      set.insert(fillHead..<fillEnd)
      fillHead = fillEnd
      maximumIntervals = max(maximumIntervals, set.ranges.count)
    }

    XCTAssertLessThanOrEqual(maximumIntervals, fronts + 1)
    XCTAssertTrue(set.covers(totalSize: Self.archiveSize))
  }

  /// Where intervals lose on size, stated rather than hidden.
  ///
  /// Writes that deliberately leave a gap behind every chunk grow the record one
  /// interval per chunk, at about 30 bytes each, against a 4 KiB block map's
  /// fixed 22 KB for this archive. The crossover is therefore a few hundred
  /// simultaneous gaps: 500 of them still encode smaller than the map, 2,000 do
  /// not. The measured worst case under the patterns the archive actually sees
  /// is nine, so the crossover is three orders of magnitude away — and size is
  /// not what decides this anyway (see the correctness tests below).
  func testRecordSize_AgainstABlockMap_CrossesOverAtAFewHundredGaps() {
    let mapBytes = Int(Self.archiveSize / (4 << 10)) / 8  // one bit per 4 KiB block

    func recordBytes(gaps: Int) -> Int {
      var set = ByteRangeSet()
      for index in 0..<gaps {
        let start = UInt64(index) * 2 * Self.fillChunk
        set.insert(start..<(start + Self.fillChunk))
      }
      XCTAssertEqual(set.ranges.count, gaps, "alternating writes should not merge")
      return set.ranges.reduce(0) { $0 + PartialArchiveStore.recordLineLength($1) }
    }

    XCTAssertLessThan(recordBytes(gaps: 500), mapBytes)
    XCTAssertGreaterThan(recordBytes(gaps: 2_000), mapBytes)
  }

  // MARK: What a block map costs in correctness

  /// The decisive argument, and it is not about size.
  ///
  /// A block map can only be honest about an unaligned write by discarding the
  /// partial blocks at its edges, and the transport picks those edges. Replaying
  /// one sequential fill through both representations, the intervals hold every
  /// byte delivered and a 4 KiB map holds about 91.5% of them: roughly 60 MB of
  /// this 700 MB archive is on disk, cannot be admitted to, and would be fetched
  /// a second time. That is the egress this work exists to remove.
  func testBlockMap_OnUnalignedDeliveries_LosesBytesThatAreOnDisk() {
    var set = ByteRangeSet()
    var map = HonestBlockMap(blockSize: 4 << 10)
    var offset: UInt64 = 0

    while offset < Self.archiveSize {
      let end = min(offset + Self.deliveryChunk, Self.archiveSize)
      set.insert(offset..<end)
      map.insert(offset..<end)
      offset = end
    }

    XCTAssertEqual(set.byteCount, Self.archiveSize, "intervals lost a delivered byte")
    XCTAssertLessThan(
      map.byteCount, Self.archiveSize * 92 / 100,
      "the block map was expected to lose around 8.5% of the delivered bytes"
    )
    XCTAssertGreaterThan(map.byteCount, Self.archiveSize * 88 / 100, "loss larger than measured")
  }

  /// The same loss at the granularity the cipher cares about. Even a 16-byte
  /// map, fine enough to be useless as a compression of the record, still
  /// cannot record an unaligned delivery exactly.
  func testBlockMap_EvenAtCipherBlockGranularity_StillLosesBytes() {
    var map = HonestBlockMap(blockSize: PartialArchiveStore.cipherBlockSize)
    var offset: UInt64 = 0
    let limit: UInt64 = 10 << 20

    while offset < limit {
      let end = min(offset + 1001, limit)  // unaligned deliveries
      map.insert(offset..<end)
      offset = end
    }

    XCTAssertLessThan(map.byteCount, limit)
  }

  /// And the loss is not recoverable by a later neighbouring write under a map
  /// that marks per write, which is what makes it a permanent refetch rather
  /// than a rounding error.
  func testBlockMap_WhenAdjacentWritesCompleteABlock_StillReportsItMissing() {
    var map = HonestBlockMap(blockSize: 4 << 10)
    map.insert(0..<1000)
    map.insert(1000..<4096)

    XCTAssertFalse(map.contains(0), "a block map marking per write cannot see the completed block")

    var set = ByteRangeSet()
    set.insert(0..<1000)
    set.insert(1000..<4096)

    XCTAssertTrue(set.contains(0..<4096))
  }
}
