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

    // First interval that reaches `lower` — i.e. that could overlap or touch.
    var low = 0
    var high = ranges.count
    while low < high {
      let mid = low + (high - low) / 2
      if ranges[mid].upperBound < lower { low = mid + 1 } else { high = mid }
    }

    var end = low
    while end < ranges.count, ranges[end].lowerBound <= upper {
      lower = min(lower, ranges[end].lowerBound)
      upper = max(upper, ranges[end].upperBound)
      end += 1
    }

    ranges.replaceSubrange(low..<end, with: CollectionOfOne(lower..<upper))
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
  func blockAlignedInward(blockSize: UInt64) -> ByteRangeSet {
    precondition(blockSize > 0, "block size must be positive")
    guard blockSize > 1 else { return self }
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
    ranges.count == 1 && ranges[0].lowerBound == 0 && ranges[0].upperBound == totalSize
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
