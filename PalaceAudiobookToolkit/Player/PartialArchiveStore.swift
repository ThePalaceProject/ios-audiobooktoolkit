//
//  PartialArchiveStore.swift
//  PalaceAudiobookToolkit
//
//  A partially-downloaded archive on disk, plus an exact record of which of its
//  byte ranges are present, so one transfer can serve both playback and
//  offline. The ordering guarantee this type exists to provide is in the doc
//  comment on `write(_:at:)`.
//

import Darwin
import Foundation

// MARK: - ByteRangeCoverage

/// What part of a requested range is on disk and what part is not.
public struct ByteRangeCoverage: Equatable, Sendable {
  /// Sorted, disjoint, non-adjacent, and clipped to the query.
  public let present: [Range<UInt64>]
  /// The complement of `present` within the query, same guarantees.
  public let missing: [Range<UInt64>]

  public var isFullyPresent: Bool { missing.isEmpty }

  public init(present: [Range<UInt64>], missing: [Range<UInt64>]) {
    self.present = present
    self.missing = missing
  }
}

// MARK: - PartialArchiveStoreError

public enum PartialArchiveStoreError: Error, Equatable, Sendable {
  /// A zero-length archive has no meaningful completeness, so it is refused at
  /// open rather than reported complete.
  case invalidTotalSize(UInt64)
  /// The stored archive was created for a different total size. The caller
  /// decides whether to `delete()` and start again; the store will not
  /// reinterpret bytes it already holds against a new size.
  case totalSizeMismatch(recorded: UInt64, requested: UInt64)
  case rangeOutOfBounds(Range<UInt64>, totalSize: UInt64)
  /// A read asked for bytes that are not present. `missing` names the gaps so
  /// the caller can fetch exactly those.
  case notPresent(missing: [Range<UInt64>])
  /// Another `PartialArchiveStore` holds this directory.
  case alreadyOpen(URL)
  case closed
  /// The write ran out of space. `committed` bytes did reach the disk and were
  /// recorded, so a retry need only refetch the tail.
  case outOfSpace(committed: UInt64)
  case io(code: Int32, path: String)
}

// MARK: - PartialArchiveStore

/// A single partially-present archive file and the index of its present bytes.
///
/// Synchronous and internally serialised: every method may be called from any
/// thread. It performs blocking file I/O, so it must not be called from the
/// main thread or from inside an actor.
public final class PartialArchiveStore: @unchecked Sendable {

  // MARK: File layout

  /// Named `.lcpa` because a complete store's data file *is* the archive and
  /// gets handed on as one; the store itself reads no archive structure.
  static let archiveFileName = "archive.lcpa"
  static let journalFileName = "archive.ranges"
  static let lockFileName = "archive.lock"
  static let journalMagic = "PARV1"

  /// Above this many accepted records, the journal is rewritten from the merged
  /// set at open. Only bounds file growth; no caller behaviour depends on it.
  static let compactionThreshold = 512

  // MARK: Durability seam

  /// Makes already-written bytes durable. Must return only once a power loss
  /// could no longer lose them.
  ///
  /// Injectable for one reason: a test barrier that performs the real flush and
  /// then throws reproduces, through the real write path, the exact on-disk
  /// state a process kill leaves between the data write and the journal append.
  /// That window is the only one in which this type could ever lie.
  typealias DurabilityBarrier = @Sendable (_ descriptor: Int32, _ path: String) throws -> Void

  /// `F_FULLFSYNC` rather than `fsync`: on Apple platforms `fsync` may return
  /// before the drive has flushed its own write cache, which would leave the
  /// journal recording bytes a power loss can still take back.
  static let fullFlushBarrier: DurabilityBarrier = { descriptor, path in
    if fcntl(descriptor, F_FULLFSYNC) != -1 { return }
    // Some filesystems do not implement F_FULLFSYNC; fsync is then the
    // strongest available.
    if fsync(descriptor) == -1 {
      throw PartialArchiveStoreError.io(code: errno, path: path)
    }
  }

  // MARK: Free space seam

  /// Bytes still available for this volume, or nil when it cannot be
  /// determined.
  typealias FreeSpaceProbe = @Sendable (_ directory: URL) -> UInt64?

  /// Asked before every fill, not once at open: the archive file is created at
  /// its final logical length and the volume fills underneath it over the
  /// minutes or hours a download takes, so a single check at the start would
  /// say nothing about the write that actually runs out of room.
  ///
  /// `volumeAvailableCapacityForImportantUsage` rather than the raw free blocks
  /// because it is the figure that accounts for purgeable space, so it does not
  /// refuse a write the system would in fact have made room for.
  static let systemFreeSpaceProbe: FreeSpaceProbe = { directory in
    let values = try? directory.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    )
    return availableBytes(forCapacity: values?.volumeAvailableCapacityForImportantUsage)
  }

  /// Turns a reported volume capacity into an available-byte count.
  ///
  /// Separate from the Foundation call so the decision can be tested: a missing
  /// or non-positive figure becomes "unknown", which does NOT block a write,
  /// rather than "no space", which would block every one.
  static func availableBytes(forCapacity capacity: Int64?) -> UInt64? {
    guard let capacity, capacity > 0 else { return nil }
    return UInt64(capacity)
  }

  // MARK: Raw write seam

  /// One `pwrite`. Returns the byte count, or a negative value with `errno`
  /// set, exactly as the syscall does.
  ///
  /// Injectable for the same reason as the barrier: a volume that fills in the
  /// middle of a chunk cannot be produced inside a simulator, and the decision
  /// this makes — record the prefix that reached the disk and nothing beyond it
  /// — is the one that keeps a partially written chunk from being claimed in
  /// full. The retry and accounting loop around it stays in production code.
  typealias RawWrite = @Sendable (
    _ descriptor: Int32,
    _ bytes: UnsafeRawPointer,
    _ count: Int,
    _ offset: off_t
  ) -> Int

  static let systemRawWrite: RawWrite = { descriptor, bytes, count, offset in
    pwrite(descriptor, bytes, count, offset)
  }

  // MARK: Cipher grid

  /// Whether a total size is one this store can address.
  ///
  /// Bounded above as well as below: every offset reaches the filesystem as an
  /// `off_t`, which is signed, so a larger size would trap on conversion
  /// rather than be refused — and a server's Content-Length is not a trusted
  /// number. A separate function because that is the only way to pin the upper
  /// boundary; reaching it through `open` would mean asking a filesystem to
  /// truncate a file to 9.2 exabytes.
  static func isAddressable(totalSize: UInt64) -> Bool {
    totalSize > 0 && totalSize <= UInt64(Int64.max)
  }

  /// AES block size. The archive's payload is AES-CBC, so a reader can only
  /// decrypt whole blocks.
  public static let cipherBlockSize: UInt64 = 16

  /// The ciphertext a reader must hold to decrypt the plaintext `range`: the
  /// block containing the first byte, through one block past the block
  /// containing the last, clipped to the archive.
  ///
  /// CBC chains each block onto the previous one, so the window carries a block
  /// of lead-in and a block of lead-out rather than being a tight cover.
  public static func decryptableWindow(
    for range: Range<UInt64>,
    totalSize: UInt64
  ) -> Range<UInt64> {
    guard !range.isEmpty, range.lowerBound < totalSize else {
      let anchor = min(range.lowerBound, totalSize)
      return anchor..<anchor
    }
    let lower = range.lowerBound.roundedDownToMultiple(of: cipherBlockSize)
    let last = min(range.upperBound, totalSize) - 1
    let upper = min(last.roundedDownToMultiple(of: cipherBlockSize) + 2 * cipherBlockSize, totalSize)
    return lower..<upper
  }

  // MARK: State

  public let totalSize: UInt64
  public let archiveURL: URL

  private let directory: URL
  private let journalURL: URL
  private let lockURL: URL
  private let barrier: DurabilityBarrier
  private let freeSpace: FreeSpaceProbe
  private let rawWrite: RawWrite

  private let mutex = NSLock()
  private var ranges: ByteRangeSet
  private var archiveDescriptor: Int32
  private var journalDescriptor: Int32
  private var lockDescriptor: Int32
  private var isClosed = false

  // MARK: Lifecycle

  /// Opens the store for one book, creating it if it does not exist.
  ///
  /// Holds an exclusive advisory lock on the directory for the store's
  /// lifetime, so a second opener fails with `.alreadyOpen` instead of two
  /// writers interleaving appends into one journal.
  public static func open(directory: URL, totalSize: UInt64) throws -> PartialArchiveStore {
    try PartialArchiveStore(
      directory: directory,
      totalSize: totalSize,
      barrier: fullFlushBarrier,
      freeSpace: systemFreeSpaceProbe,
      rawWrite: systemRawWrite
    )
  }

  init(
    directory: URL,
    totalSize: UInt64,
    barrier: @escaping DurabilityBarrier,
    freeSpace: @escaping FreeSpaceProbe = systemFreeSpaceProbe,
    rawWrite: @escaping RawWrite = systemRawWrite
  ) throws {
    // Every stored property is set before the first `throw`: a class
    // initializer may not throw while any of them is still uninitialized.
    self.directory = directory
    self.totalSize = totalSize
    self.barrier = barrier
    self.freeSpace = freeSpace
    self.rawWrite = rawWrite
    archiveURL = directory.appendingPathComponent(Self.archiveFileName)
    journalURL = directory.appendingPathComponent(Self.journalFileName)
    lockURL = directory.appendingPathComponent(Self.lockFileName)
    ranges = ByteRangeSet()
    archiveDescriptor = -1
    journalDescriptor = -1
    lockDescriptor = -1

    // Upper bound as well as lower: every offset reaches the filesystem as an
    // `off_t`, which is signed, so a larger size would trap on conversion
    // rather than be refused. A server Content-Length is not a trusted number.
    guard Self.isAddressable(totalSize: totalSize) else {
      isClosed = true
      throw PartialArchiveStoreError.invalidTotalSize(totalSize)
    }

    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      lockDescriptor = try Self.openDescriptor(lockURL, flags: O_RDWR | O_CREAT)
      guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        // `EAGAIN` is not also tested: on Darwin it is the same value as
        // `EWOULDBLOCK`, so a second comparison cannot change the answer.
        throw code == EWOULDBLOCK
          ? PartialArchiveStoreError.alreadyOpen(directory)
          : PartialArchiveStoreError.io(code: code, path: lockURL.path)
      }

      let loaded = try Self.loadJournal(at: journalURL, totalSize: totalSize)
      ranges = loaded.ranges
      // A rewrite emits the header itself, so the two are exclusive.
      let needsRewrite = loaded.recordCount > Self.compactionThreshold || loaded.hadTrailingDamage
      if needsRewrite {
        try Self.rewriteJournal(
          at: journalURL, in: directory, totalSize: totalSize, ranges: ranges, barrier: barrier
        )
      }
      journalDescriptor = try Self.openDescriptor(journalURL, flags: O_WRONLY | O_APPEND | O_CREAT)
      if loaded.isNew, !needsRewrite {
        try Self.appendLine(
          Self.headerLine(totalSize: totalSize),
          to: journalDescriptor,
          path: journalURL.path,
          barrier: barrier
        )
      }
      archiveDescriptor = try Self.openDescriptor(archiveURL, flags: O_RDWR | O_CREAT)

      // Give the file its final logical length up front. APFS keeps it sparse
      // at archive scale (a 100 MB extent measured 12 KB allocated), so this
      // costs nothing it will not eventually need, and it means a write never
      // has to extend the file. Measured sparseness does NOT hold at small
      // sizes — a 1 MB file allocated in full — so this is not a general claim
      // about `ftruncate`, only about the sizes an audiobook archive has.
      //
      // The consequence every reader must know: `st_size` now reports the full
      // length from the first byte written, and an unwritten extent reads back
      // as zeros. Nothing downstream can tell those zeros from content, so the
      // journal is the only authority on what is present.
      var status = stat()
      let needsTruncate = fstat(archiveDescriptor, &status) != 0
        || UInt64(status.st_size) != totalSize
      if needsTruncate, ftruncate(archiveDescriptor, off_t(totalSize)) != 0 {
        throw PartialArchiveStoreError.io(code: errno, path: archiveURL.path)
      }
    } catch {
      releaseDescriptors()
      isClosed = true
      throw error
    }
  }

  deinit {
    if !isClosed { releaseDescriptors() }
  }

  /// Releases the descriptors and the lock. Queries keep answering from the
  /// in-memory set, which reads no file; reads and writes throw `.closed`.
  public func close() {
    mutex.withLock {
      guard !isClosed else { return }
      releaseDescriptors()
      isClosed = true
    }
  }

  /// Removes the archive, its journal and its lock. Safe after `close()`, and
  /// safe to call twice.
  public func delete() throws {
    try mutex.withLock {
      if !isClosed {
        releaseDescriptors()
        isClosed = true
      }
      ranges = ByteRangeSet()
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    }
  }

  // MARK: Ask

  public func coverage(of range: Range<UInt64>) -> ByteRangeCoverage {
    let query = clamped(range)
    return mutex.withLock {
      ByteRangeCoverage(present: ranges.present(in: query), missing: ranges.missing(in: query))
    }
  }

  public func missingRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
    let query = clamped(range)
    return mutex.withLock { ranges.missing(in: query) }
  }

  /// Coverage of the ciphertext window needed to decrypt the plaintext `range`,
  /// counting only whole cipher blocks as present.
  ///
  /// Three different roundings meet here, and the difference between them is
  /// the difference between a refetch and garbage audio:
  ///
  /// - the query rounds OUTWARD, to the window CBC actually needs
  ///   (`decryptableWindow`), so the answer is about the bytes the caller will
  ///   really read;
  /// - what is reported present rounds INWARD to the block grid, so a partial
  ///   block at the edge of a stored interval is reported missing rather than
  ///   handed over as an undecryptable fragment;
  /// - `missing` therefore comes back on the block grid too, so fetching it
  ///   yields a decryptable window in turn.
  ///
  /// The stored record itself is rounded neither way: it stays byte-exact, so
  /// the bytes trimmed inward here are still known and are not refetched when a
  /// neighbouring write makes their block whole.
  public func decryptableCoverage(of range: Range<UInt64>) -> ByteRangeCoverage {
    let window = Self.decryptableWindow(for: range, totalSize: totalSize)
    return mutex.withLock {
      let aligned = ranges.blockAlignedInward(blockSize: Self.cipherBlockSize)
      return ByteRangeCoverage(
        present: aligned.present(in: window),
        missing: aligned.missing(in: window)
      )
    }
  }

  /// Whether every byte of the archive is present. Exact: one interval
  /// covering [0, `totalSize`).
  public func isComplete() -> Bool {
    mutex.withLock { ranges.covers(totalSize: totalSize) }
  }

  public func bytesPresent() -> UInt64 {
    mutex.withLock { ranges.byteCount }
  }

  // MARK: Write

  /// Writes `bytes` at `offset` and records the range, in that order.
  ///
  /// The ordering guarantee, which everything else here serves: **the journal
  /// never names a byte that is not already durable on disk.** The sequence is
  ///
  ///   1. `pwrite` the bytes into the archive,
  ///   2. flush the archive through `barrier` — after this a power loss cannot
  ///      take those bytes back,
  ///   3. append one record naming the range to the journal and flush that,
  ///   4. only then add the range to the in-memory set.
  ///
  /// A kill between any two steps leaves the journal claiming *less* than the
  /// file holds, never more. Under-claiming costs a refetch of bytes that were
  /// already there; over-claiming would serve whatever happened to be at those
  /// offsets as if it were audio, from a file that looks healthy. Only one of
  /// those two is survivable, which is why the flush in step 2 is not
  /// negotiable and why nothing is recorded before it.
  ///
  /// The journal is append-only, one `<lower> <upper> <crc32>` line per
  /// committed range, so a kill mid-append can only damage the final line.
  /// `loadJournal` accepts the longest prefix of intact records and stops at
  /// the first damaged one, which loses at most the last write.
  ///
  /// - Returns: the range actually committed, which is shorter than `bytes` only
  ///   when the write could not complete.
  @discardableResult
  public func write(_ bytes: Data, at offset: UInt64) throws -> Range<UInt64> {
    try mutex.withLock {
      guard !isClosed else { throw PartialArchiveStoreError.closed }
      guard !bytes.isEmpty else { return offset..<offset }

      let requested = offset..<(offset + UInt64(bytes.count))
      guard requested.upperBound <= totalSize else {
        throw PartialArchiveStoreError.rangeOutOfBounds(requested, totalSize: totalSize)
      }

      // Refuse before writing when the volume cannot take these bytes. The
      // short-write path below is still the authority — a probe can only be
      // stale — but failing here keeps the common case from leaving a
      // half-written chunk behind. An unknown figure does not block the write.
      if let available = freeSpace(directory), available < UInt64(bytes.count) {
        throw PartialArchiveStoreError.outOfSpace(committed: 0)
      }

      var written = 0
      var failure: PartialArchiveStoreError?
      bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        let transfer = Self.transferAll(total: raw.count) { alreadyMoved in
          rawWrite(
            archiveDescriptor,
            base.advanced(by: alreadyMoved),
            raw.count - alreadyMoved,
            off_t(offset) + off_t(alreadyMoved)
          )
        }
        written = transfer.moved
        guard let code = transfer.errorCode else { return }
        failure = (code == ENOSPC || code == EDQUOT)
          ? .outOfSpace(committed: UInt64(written))
          : .io(code: code, path: archiveURL.path)
      }

      let committed = offset..<(offset + UInt64(written))
      if written > 0 {
        try barrier(archiveDescriptor, archiveURL.path)
        try Self.appendLine(
          Self.recordLine(committed),
          to: journalDescriptor,
          path: journalURL.path,
          barrier: barrier
        )
        ranges.insert(committed)
      }

      if let failure { throw failure }
      return committed
    }
  }

  // MARK: Read

  /// The whole range or nothing: throws `.notPresent(missing:)` naming the gaps
  /// rather than returning the bytes it happens to have, because a short read
  /// of an archive is indistinguishable from a corrupt one at the call site.
  public func read(_ range: Range<UInt64>) throws -> Data {
    try mutex.withLock {
      guard !isClosed else { throw PartialArchiveStoreError.closed }
      guard !range.isEmpty else { return Data() }
      guard range.upperBound <= totalSize else {
        throw PartialArchiveStoreError.rangeOutOfBounds(range, totalSize: totalSize)
      }
      let gaps = ranges.missing(in: range)
      guard gaps.isEmpty else { throw PartialArchiveStoreError.notPresent(missing: gaps) }
      return try readLocked(offset: range.lowerBound, length: range.count)
    }
  }

  /// The contiguous present run starting at `offset`, capped at `maxLength`.
  /// Empty when `offset` itself is missing.
  ///
  /// Deliberately short rather than throwing: this is the serve-what-we-have
  /// primitive, and its caller is asking how far it can get from `offset`.
  public func readContiguous(from offset: UInt64, maxLength: Int) throws -> Data {
    try mutex.withLock {
      guard !isClosed else { throw PartialArchiveStoreError.closed }
      // No `offset < totalSize` test: `contiguousRun` is empty for any offset
      // the set does not hold, and the set never holds `totalSize`, so the
      // clause could not change the answer. `maxLength > 0` is load-bearing —
      // it guards the `UInt64` conversion below, which traps on a negative.
      guard maxLength > 0 else { return Data() }
      let run = ranges.contiguousRun(from: offset)
      guard !run.isEmpty else { return Data() }
      let length = Int(min(UInt64(maxLength), run.upperBound - offset))
      return try readLocked(offset: offset, length: length)
    }
  }

  // MARK: - Private

  private func clamped(_ range: Range<UInt64>) -> Range<UInt64> {
    let lower = min(range.lowerBound, totalSize)
    let upper = min(max(range.upperBound, lower), totalSize)
    return lower..<upper
  }

  private func releaseDescriptors() {
    if archiveDescriptor != -1 { Darwin.close(archiveDescriptor); archiveDescriptor = -1 }
    if journalDescriptor != -1 { Darwin.close(journalDescriptor); journalDescriptor = -1 }
    if lockDescriptor != -1 {
      flock(lockDescriptor, LOCK_UN)
      Darwin.close(lockDescriptor)
      lockDescriptor = -1
    }
  }

  /// How many times a transfer may be interrupted without moving a byte before
  /// it is reported as failed.
  ///
  /// Exists so the loop below has an upper bound that does not depend on
  /// arithmetic inside it. Three mutants of the hand-written loops this
  /// replaced made them spin forever, and the suite then HUNG at a 180 s
  /// timeout rather than failing an assertion — which is indistinguishable from
  /// infrastructure flakiness, and is how a real hang reaches production
  /// unnoticed. Bounding the loop turns that class into an ordinary failure.
  private static let interruptionAllowance = 64

  /// Drives a partial-transfer syscall to completion, or to the first error.
  ///
  /// `attempt` is given the number of bytes already moved and returns the
  /// syscall's result: a positive count, or a negative value with `errno` set.
  ///
  /// - Returns: how many bytes moved, and the `errno` to report if it did not
  ///   finish.
  private static func transferAll(
    total: Int,
    attempt: (_ alreadyMoved: Int) -> Int
  ) -> (moved: Int, errorCode: Int32?) {
    var moved = 0
    for _ in 0..<(total + interruptionAllowance) {
      if moved >= total { return (moved, nil) }
      let count = attempt(moved)
      if count > 0 {
        moved += count
        continue
      }
      // A zero-length result for a non-zero request is not progress, so
      // retrying it would spin.
      if count == 0 { return (moved, EIO) }
      if errno == EINTR { continue }
      return (moved, errno)
    }
    // Reaching here means the allowance ran out without finishing: the check
    // at the top of the loop returns as soon as `moved` reaches `total`, so
    // this path cannot be a success.
    return (moved, EINTR)
  }

  /// A short read here means the file is smaller than the journal says, i.e.
  /// the one thing this type promises cannot happen. It is an error, never a
  /// short result.
  private func readLocked(offset: UInt64, length: Int) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: length)
    var failureCode: Int32?
    buffer.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      failureCode = Self.transferAll(total: length) { alreadyMoved in
        pread(
          archiveDescriptor,
          base.advanced(by: alreadyMoved),
          length - alreadyMoved,
          off_t(offset) + off_t(alreadyMoved)
        )
      }.errorCode
    }
    if let failureCode {
      throw PartialArchiveStoreError.io(code: failureCode, path: archiveURL.path)
    }
    return Data(buffer)
  }

  // MARK: Journal

  private struct LoadedJournal {
    var ranges: ByteRangeSet
    var recordCount: Int
    /// A damaged or unterminated final record was discarded, so the file on
    /// disk is not a clean prefix and gets rewritten.
    var hadTrailingDamage: Bool
    var isNew: Bool
  }

  private static func headerLine(totalSize: UInt64) -> String {
    "\(journalMagic) \(totalSize)"
  }

  private static func recordLine(_ range: Range<UInt64>) -> String {
    let body = "\(range.lowerBound) \(range.upperBound)"
    return "\(body) \(crc32(Array(body.utf8)))"
  }

  /// Bytes one interval costs in the journal, newline included. Exposed so the
  /// size of the record can be measured against the alternatives rather than
  /// estimated.
  static func recordLineLength(_ range: Range<UInt64>) -> Int {
    recordLine(range).utf8.count + 1
  }

  /// Reads the journal, accepting the longest prefix of intact records.
  ///
  /// Anything it cannot vouch for is dropped, and it stops at the first damaged
  /// record rather than skipping it — with an append-only file, a damaged record
  /// means the tail is untrustworthy, and under-claiming is the only safe way to
  /// be wrong.
  private static func loadJournal(at url: URL, totalSize: UInt64) throws -> LoadedJournal {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      return LoadedJournal(ranges: ByteRangeSet(), recordCount: 0, hadTrailingDamage: false, isNew: true)
    }

    // Only newline-terminated lines are considered: a kill mid-append leaves a
    // fragment with no newline, and a fragment is not a record.
    var lines: [String] = []
    var start = data.startIndex
    var sawTerminator = false
    for index in data.indices where data[index] == UInt8(ascii: "\n") {
      lines.append(String(decoding: data[start..<index], as: UTF8.self))
      start = data.index(after: index)
      sawTerminator = true
    }
    let hadFragment = !sawTerminator || start != data.endIndex

    guard let header = lines.first else {
      // Bytes with no complete line at all: nothing can be vouched for.
      return LoadedJournal(ranges: ByteRangeSet(), recordCount: 0, hadTrailingDamage: true, isNew: true)
    }

    let headerFields = header.split(separator: " ")
    guard headerFields.count == 2, headerFields[0] == journalMagic,
          let recorded = UInt64(headerFields[1])
    else {
      // Unreadable header: treat the store as empty rather than guess which
      // archive these bytes belong to.
      return LoadedJournal(ranges: ByteRangeSet(), recordCount: 0, hadTrailingDamage: true, isNew: true)
    }
    guard recorded == totalSize else {
      throw PartialArchiveStoreError.totalSizeMismatch(recorded: recorded, requested: totalSize)
    }

    var set = ByteRangeSet()
    var accepted = 0
    var stoppedEarly = false
    for line in lines.dropFirst() {
      // A record outside the archive cannot be produced by `write`, which
      // bounds-checks first. Treating it as damage rather than clamping it
      // keeps the record from ever describing bytes that cannot exist.
      guard let range = parseRecord(line), range.upperBound <= totalSize else {
        stoppedEarly = true
        break
      }
      set.insert(range)
      accepted += 1
    }

    return LoadedJournal(
      ranges: set,
      recordCount: accepted,
      hadTrailingDamage: stoppedEarly || hadFragment,
      isNew: false
    )
  }

  private static func parseRecord(_ line: String) -> Range<UInt64>? {
    let fields = line.split(separator: " ")
    guard fields.count == 3,
          let lower = UInt64(fields[0]),
          let upper = UInt64(fields[1]),
          let checksum = UInt32(fields[2]),
          lower < upper
    else { return nil }
    guard crc32(Array("\(lower) \(upper)".utf8)) == checksum else { return nil }
    return lower..<upper
  }

  private static func appendLine(
    _ line: String,
    to descriptor: Int32,
    path: String,
    barrier: DurabilityBarrier
  ) throws {
    let bytes = Array((line + "\n").utf8)
    var failureCode: Int32?
    bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      failureCode = transferAll(total: raw.count) { alreadyMoved in
        // The descriptor is `O_APPEND`, so every write lands at the end
        // whatever else has happened to the file.
        Darwin.write(descriptor, base.advanced(by: alreadyMoved), raw.count - alreadyMoved)
      }.errorCode
    }
    if let failureCode {
      throw PartialArchiveStoreError.io(code: failureCode, path: path)
    }
    try barrier(descriptor, path)
  }

  /// Rewrites the journal as a header plus one record per merged interval,
  /// atomically. Used at open only — never while writes are in flight — so the
  /// rename can never race an append.
  private static func rewriteJournal(
    at url: URL,
    in directory: URL,
    totalSize: UInt64,
    ranges: ByteRangeSet,
    barrier: DurabilityBarrier
  ) throws {
    let temporary = directory.appendingPathComponent("\(journalFileName).rewriting")
    try? FileManager.default.removeItem(at: temporary)
    let descriptor = try openDescriptor(temporary, flags: O_WRONLY | O_CREAT | O_TRUNC)
    defer { Darwin.close(descriptor) }

    var body = headerLine(totalSize: totalSize) + "\n"
    for range in ranges.ranges { body += recordLine(range) + "\n" }
    try appendLine(String(body.dropLast()), to: descriptor, path: temporary.path, barrier: barrier)

    guard rename(temporary.path, url.path) == 0 else {
      throw PartialArchiveStoreError.io(code: errno, path: url.path)
    }
    // The rename itself must be durable, or a crash can resurrect the old
    // journal; that needs a flush of the directory, not of either file.
    let directoryDescriptor = try openDescriptor(directory, flags: O_RDONLY)
    defer { Darwin.close(directoryDescriptor) }
    try barrier(directoryDescriptor, directory.path)
  }

  private static func openDescriptor(_ url: URL, flags: Int32) throws -> Int32 {
    let descriptor = Darwin.open(url.path, flags, 0o644)
    // `-1` exactly, not `< 0`: that is what `open` returns on failure, and
    // testing a range instead would also reject descriptor 0.
    guard descriptor != -1 else {
      throw PartialArchiveStoreError.io(code: errno, path: url.path)
    }
    return descriptor
  }

  /// CRC-32 (IEEE 802.3). Bitwise rather than table-driven: a record is about
  /// twenty bytes, so the table would cost more than it saves.
  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
      }
    }
    return ~crc
  }
}

// MARK: - ArchiveRangeStore

/// The caching client needs only the four range operations this store already
/// provides, so the conformance is declarative: `totalSize`, `missingRanges(in:)`,
/// `write(_:at:)` and `read(_:)` match the protocol as written.
extension PartialArchiveStore: ArchiveRangeStore {}
