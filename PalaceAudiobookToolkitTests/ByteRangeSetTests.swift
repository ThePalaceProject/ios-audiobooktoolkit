//
//  ByteRangeSetTests.swift
//  PalaceAudiobookToolkitTests
//
//  The interval algebra behind `PartialArchiveStore`. Every answer the store
//  gives about what it holds comes from here, so a wrong answer here is a wrong
//  answer about a patron's audio.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class ByteRangeSetTests: XCTestCase {

  // MARK: Insertion and merging

  /// Two writes that touch at a boundary are one region, not two: the sequential
  /// fill produces exactly this shape on every chunk, and leaving them separate
  /// would grow the record with the number of writes and break the completeness
  /// check, which requires a single interval.
  func testInsert_WhenRangesAreAdjacent_MergesIntoOne() {
    var set = ByteRangeSet()
    set.insert(0..<10)
    set.insert(10..<20)

    XCTAssertEqual(set.ranges, [0..<20])
  }

  func testInsert_WhenRangesOverlap_MergesToTheUnion() {
    var set = ByteRangeSet()
    set.insert(0..<100)
    set.insert(50..<150)

    XCTAssertEqual(set.ranges, [0..<150])
  }

  func testInsert_WhenRangesAreSeparatedByOneByte_StaysTwoIntervals() {
    var set = ByteRangeSet()
    set.insert(0..<10)
    set.insert(11..<20)

    XCTAssertEqual(set.ranges, [0..<10, 11..<20])
  }

  /// A write that spans several existing intervals absorbs all of them. The
  /// background fill reaching a region the playhead already read does exactly
  /// this, and leaving a swallowed interval behind would double-count bytes.
  func testInsert_WhenRangeSpansSeveralIntervals_AbsorbsThemAll() {
    var set = ByteRangeSet([0..<10, 20..<30, 40..<50])
    set.insert(5..<45)

    XCTAssertEqual(set.ranges, [0..<50])
  }

  func testInsert_WhenRangeIsAlreadyContained_ChangesNothing() {
    var set = ByteRangeSet([0..<100])
    set.insert(10..<20)

    XCTAssertEqual(set.ranges, [0..<100])
  }

  func testInsert_WhenRangeIsEmpty_ChangesNothing() {
    var set = ByteRangeSet([0..<100])
    set.insert(50..<50)

    XCTAssertEqual(set.ranges, [0..<100])
  }

  /// Inserted back to front, the set must still come out sorted — the fill
  /// prioritises outward from the playhead, so descending writes are normal.
  func testInsert_WhenRangesArriveOutOfOrder_KeepsTheSetSorted() {
    var set = ByteRangeSet()
    set.insert(80..<90)
    set.insert(20..<30)
    set.insert(50..<60)

    XCTAssertEqual(set.ranges, [20..<30, 50..<60, 80..<90])
  }

  func testByteCount_WhenRangesOverlap_CountsEachByteOnce() {
    let set = ByteRangeSet([0..<100, 50..<150])

    XCTAssertEqual(set.byteCount, 150)
  }

  // MARK: Querying

  /// A read that straddles a gap must name the gap. This is the difference
  /// between refetching 10 bytes and serving 10 bytes of whatever was at that
  /// offset.
  func testMissing_WhenQuerySpansAGap_ReturnsOnlyTheGap() {
    let set = ByteRangeSet([0..<10, 20..<30])

    XCTAssertEqual(set.missing(in: 0..<30), [10..<20])
    XCTAssertEqual(set.present(in: 0..<30), [0..<10, 20..<30])
  }

  func testMissing_WhenQueryLiesEntirelyInAGap_ReturnsTheWholeQuery() {
    let set = ByteRangeSet([0..<10, 100..<200])

    XCTAssertEqual(set.missing(in: 20..<50), [20..<50])
    XCTAssertEqual(set.present(in: 20..<50), [])
  }

  func testMissing_WhenQuerySpansSeveralGaps_ReturnsEachOne() {
    let set = ByteRangeSet([0..<10, 20..<30, 40..<50])

    XCTAssertEqual(set.missing(in: 0..<50), [10..<20, 30..<40])
  }

  /// Answers are clipped to the query, not reported as the whole stored
  /// interval: a caller that fetched a reported range verbatim would otherwise
  /// refetch bytes outside what it asked about.
  func testPresent_WhenQueryIsInsideAStoredInterval_ClipsToTheQuery() {
    let set = ByteRangeSet([0..<1000])

    XCTAssertEqual(set.present(in: 100..<200), [100..<200])
    XCTAssertEqual(set.missing(in: 100..<200), [])
  }

  func testPresentAndMissing_ForAnyQuery_PartitionItExactly() {
    let set = ByteRangeSet([10..<20, 40..<60, 90..<100])
    let query: Range<UInt64> = 0..<120

    let covered = (set.present(in: query) + set.missing(in: query))
      .reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }

    XCTAssertEqual(covered, 120)
  }

  func testMissing_WhenSetIsEmpty_ReturnsTheWholeQuery() {
    let set = ByteRangeSet()

    XCTAssertEqual(set.missing(in: 0..<100), [0..<100])
  }

  func testMissing_WhenQueryIsEmpty_ReturnsNothing() {
    let set = ByteRangeSet([0..<100])

    XCTAssertEqual(set.missing(in: 50..<50), [])
    XCTAssertEqual(set.present(in: 50..<50), [])
  }

  /// The last byte of the archive is the one a half-open range is easiest to
  /// get wrong, and getting it wrong means a book that never reports complete.
  func testQuery_AtTheExactEndOfAStoredInterval_TreatsTheBoundAsExclusive() {
    let set = ByteRangeSet([0..<100])

    XCTAssertTrue(set.contains(99..<100))
    XCTAssertEqual(set.missing(in: 100..<101), [100..<101])
    XCTAssertEqual(set.present(in: 99..<100), [99..<100])
  }

  // MARK: Contiguous runs

  func testContiguousRun_FromInsideAnInterval_ReachesThatIntervalsEnd() {
    let set = ByteRangeSet([0..<100, 200..<300])

    XCTAssertEqual(set.contiguousRun(from: 40), 40..<100)
  }

  /// A run stops at the gap rather than jumping it, or a serving reader would
  /// hand over two non-adjacent regions as if they were consecutive.
  func testContiguousRun_WhenAGapFollows_StopsAtTheGap() {
    let set = ByteRangeSet([0..<100, 100..<150, 200..<300])

    XCTAssertEqual(set.contiguousRun(from: 0), 0..<150)
  }

  func testContiguousRun_FromInsideAGap_IsEmpty() {
    let set = ByteRangeSet([0..<100, 200..<300])

    XCTAssertTrue(set.contiguousRun(from: 150).isEmpty)
  }

  // MARK: Completeness

  func testCovers_WhenOneIntervalSpansTheWholeArchive_IsComplete() {
    XCTAssertTrue(ByteRangeSet([0..<500]).covers(totalSize: 500))
  }

  func testCovers_WhenAGapRemains_IsNotComplete() {
    XCTAssertFalse(ByteRangeSet([0..<100, 101..<500]).covers(totalSize: 500))
  }

  func testCovers_WhenTheFirstByteIsMissing_IsNotComplete() {
    XCTAssertFalse(ByteRangeSet([1..<500]).covers(totalSize: 500))
  }

  func testCovers_WhenTheLastByteIsMissing_IsNotComplete() {
    XCTAssertFalse(ByteRangeSet([0..<499]).covers(totalSize: 500))
  }

  func testCovers_WhenTheSetIsEmpty_IsNotComplete() {
    XCTAssertFalse(ByteRangeSet().covers(totalSize: 500))
  }

  // MARK: Block alignment

  /// Alignment trims, it never extends. The caller wants to know which whole
  /// AES blocks it holds; answering with a block it only partly holds would
  /// hand a reader an undecryptable fragment.
  func testBlockAlignedInward_TrimsPartialBlocksAtBothEnds() {
    let set = ByteRangeSet([5..<100])

    XCTAssertEqual(set.blockAlignedInward(blockSize: 16).ranges, [16..<96])
  }

  func testBlockAlignedInward_WhenAnIntervalIsAlreadyAligned_LeavesItAlone() {
    let set = ByteRangeSet([16..<96])

    XCTAssertEqual(set.blockAlignedInward(blockSize: 16).ranges, [16..<96])
  }

  /// An interval too short to contain a whole block holds no decryptable byte,
  /// so it must disappear rather than round out to one.
  func testBlockAlignedInward_WhenAnIntervalHoldsNoWholeBlock_DropsIt() {
    let set = ByteRangeSet([1..<15, 20..<28])

    XCTAssertEqual(set.blockAlignedInward(blockSize: 16).ranges, [])
  }

  func testBlockAlignedInward_NeverReportsAByteTheSetDoesNotHold() {
    let set = ByteRangeSet([5..<100, 200..<301])
    let aligned = set.blockAlignedInward(blockSize: 16)

    for range in aligned.ranges {
      XCTAssertTrue(set.contains(range), "alignment invented \(range)")
    }
  }

  func testRoundedUpToMultiple_AtTheTopOfTheRange_SaturatesRatherThanTrapping() {
    XCTAssertEqual((UInt64.max - 1).roundedUpToMultiple(of: 16), UInt64.max)
    XCTAssertEqual(UInt64(32).roundedUpToMultiple(of: 16), 32)
    XCTAssertEqual(UInt64(33).roundedUpToMultiple(of: 16), 48)
    XCTAssertEqual(UInt64(33).roundedDownToMultiple(of: 16), 32)
  }
}
