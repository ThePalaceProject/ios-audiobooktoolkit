//
//  ByteRangeSet.swift
//  PalaceAudiobookToolkit
//
//  The byte offsets of a file that are present locally, held as merged
//  contiguous intervals: sorted, disjoint, never adjacent. Internal to
//  `PartialArchiveStore`, whose public surface speaks only in `Range<UInt64>`,
//  so another encoding could replace this without touching a caller.
//

import Foundation

/// A set of byte offsets, stored as merged contiguous intervals.
///
/// The merge-on-insert invariant is what makes the whole store cheap: both of
/// its writers advance mostly forward, so the set converges on a single
/// interval, and "is the archive complete" becomes one comparison rather than
/// a scan.
struct ByteRangeSet: Equatable, Sendable {

  /// Sorted by `lowerBound`, pairwise disjoint, and never adjacent — two
  /// intervals that touch are one interval. Every query below relies on all
  /// three, and `insert` is the only thing that can establish them.
  private(set) var ranges: [Range<UInt64>] = []

  init() {}

  init(_ ranges: some Sequence<Range<UInt64>>) {
    for range in ranges { insert(range) }
  }

  var isEmpty: Bool { ranges.isEmpty }

  /// Total number of bytes in the set.
  var byteCount: UInt64 {
    ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
  }

  /// Adds `range`, absorbing every interval it overlaps or merely touches.
  ///
  /// Touching counts as overlapping: [0,10) and [10,20) become [0,20). Leaving
  /// them separate would make the set's size grow with the number of writes
  /// instead of the number of actual gaps, and would make the completeness
  /// check below wrong.
  mutating func insert(_ range: Range<UInt64>) {
    guard !range.isEmpty else { return }

    var lower = range.lowerBound
    var upper = range.upperBound

    // The first interval that reaches `lower`, so the first that could overlap
    // or touch it.
    //
    // Both of these are bounded by the collection rather than by arithmetic the
    // loop does itself. An index loop here is what lets a one-character change
    // spin forever, and a test can only observe that as a hang: three such
    // mutants timed out at 180 s rather than failing an assertion. A linear
    // scan also costs nothing to run — the measured worst case is nine
    // intervals (`ByteRangeSetGranularityTests`).
    let start = ranges.firstIndex { $0.upperBound >= lower } ?? ranges.count

    let absorbed = ranges[start...].prefix { candidate in
      guard candidate.lowerBound <= upper else { return false }
      lower = min(lower, candidate.lowerBound)
      upper = max(upper, candidate.upperBound)
      return true
    }.count

    ranges.replaceSubrange(
      start..<(start + absorbed),
      with: CollectionOfOne(lower..<upper)
    )
  }

  /// The parts of `query` that are in the set, clipped to `query`.
  func present(in query: Range<UInt64>) -> [Range<UInt64>] {
    guard !query.isEmpty else { return [] }
    var result: [Range<UInt64>] = []
    for range in ranges {
      if range.upperBound <= query.lowerBound { continue }
      if range.lowerBound >= query.upperBound { break }
      result.append(
        max(range.lowerBound, query.lowerBound)..<min(range.upperBound, query.upperBound)
      )
    }
    return result
  }

  /// The parts of `query` that are not in the set, clipped to `query`.
  ///
  /// Derived from `present` rather than computed separately so the two answers
  /// cannot disagree: together they always partition `query` exactly.
  func missing(in query: Range<UInt64>) -> [Range<UInt64>] {
    guard !query.isEmpty else { return [] }
    var result: [Range<UInt64>] = []
    var cursor = query.lowerBound
    for range in present(in: query) {
      if cursor < range.lowerBound { result.append(cursor..<range.lowerBound) }
      cursor = range.upperBound
    }
    if cursor < query.upperBound { result.append(cursor..<query.upperBound) }
    return result
  }

  func contains(_ query: Range<UInt64>) -> Bool {
    missing(in: query).isEmpty
  }

  /// The run of present bytes starting exactly at `offset`, or an empty range
  /// when `offset` itself is absent.
  ///
  /// This is what a reader serving a request from disk needs: how far it can go
  /// from where it was asked to start, without having to stitch intervals.
  func contiguousRun(from offset: UInt64) -> Range<UInt64> {
    for range in ranges {
      if range.lowerBound > offset { break }
      if range.contains(offset) { return offset..<range.upperBound }
    }
    return offset..<offset
  }

  /// The set shrunk to whole multiples of `blockSize`: each interval's start
  /// rounds up and its end rounds down, and an interval too short to contain a
  /// whole block disappears.
  ///
  /// Rounding INWARD, never outward. The caller's reason for wanting an aligned
  /// view is that a partial AES-CBC block cannot be decrypted, so the question
  /// it is really asking is "which whole blocks do I hold", and the answer to
  /// that is a subset of what is present. Rounding the stored intervals outward
  /// would answer with bytes that are not on disk, which is the one thing this
  /// store must never do.
  ///
  /// This is a derived view, computed per query: the stored set itself stays
  /// byte-exact, so the up-to-`blockSize`-1 bytes trimmed here are still known
  /// to be present and are never refetched.
  /// `blockSize` must be positive. Not guarded: the only caller passes
  /// `PartialArchiveStore.cipherBlockSize`, and a guard here could not be
  /// covered by a test — the arithmetic below traps on zero either way.
  func blockAlignedInward(blockSize: UInt64) -> ByteRangeSet {
    var result = ByteRangeSet()
    for range in ranges {
      let lower = range.lowerBound.roundedUpToMultiple(of: blockSize)
      let upper = range.upperBound.roundedDownToMultiple(of: blockSize)
      if lower < upper { result.ranges.append(lower..<upper) }
    }
    return result
  }

  /// Whether the set is exactly [0, `totalSize`).
  ///
  /// Exact, not a byte count: a count can reach `totalSize` while a gap remains
  /// if any byte were ever recorded twice. The merge invariant means one
  /// interval anchored at 0 and ending at `totalSize` is the only way to hold
  /// every byte.
  func covers(totalSize: UInt64) -> Bool {
    // `first` rather than `ranges[0]`: indexing is safe here only because of
    // the short-circuit, so a mutated operator crashes the test process instead
    // of failing an assertion, and a crash does not read as a finding.
    guard ranges.count == 1, let only = ranges.first else { return false }
    return only.lowerBound == 0 && only.upperBound == totalSize
  }
}

// MARK: - Grid arithmetic

extension UInt64 {
  func roundedDownToMultiple(of divisor: UInt64) -> UInt64 {
    self - (self % divisor)
  }

  /// Saturates rather than overflowing: callers clamp to the archive's size
  /// afterwards, and a trap here would be a crash on arithmetic nobody can see.
  func roundedUpToMultiple(of divisor: UInt64) -> UInt64 {
    let remainder = self % divisor
    guard remainder != 0 else { return self }
    let (sum, overflow) = addingReportingOverflow(divisor - remainder)
    return overflow ? UInt64.max : sum
  }
}
