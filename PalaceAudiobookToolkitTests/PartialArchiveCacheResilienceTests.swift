//
//  PartialArchiveCacheResilienceTests.swift
//  PalaceAudiobookToolkitTests
//
//  Two ways the partial-archive cache stopped paying for itself mid-session:
//  a single transient store-open failure disabled caching for the rest of the
//  process, and a gap-fill fallback handed the caller bytes it then discarded
//  (PP-5367).
//

import Foundation
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

// MARK: - Doubles

/// A byte-range store in memory whose writes can be refused for a chosen
/// extent, so a test can leave a window un-whole without touching a disk.
///
/// State is lock-isolated because the client commits writes on its own serial
/// queue while the test thread reads them back.
private final class ControllableRangeStore: ArchiveRangeStore {
  enum Failure: Error { case notPresent, writeRefused }

  let totalSize: UInt64

  /// A write whose extent this returns true for commits nothing and throws.
  private let refuseWrite: @Sendable (Range<UInt64>) -> Bool
  private let state = LockIsolated(Storage())

  private struct Storage: Sendable {
    var present: Set<UInt64> = []
    var writes: [Range<UInt64>] = []
  }

  init(
    totalSize: UInt64,
    refuseWrite: @escaping @Sendable (Range<UInt64>) -> Bool = { _ in false }
  ) {
    self.totalSize = totalSize
    self.refuseWrite = refuseWrite
  }

  var writes: [Range<UInt64>] { state.withValue { $0.writes } }

  func missingRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
    state.withValue { storage in
      var missing: [Range<UInt64>] = []
      var run: Range<UInt64>?
      for offset in range {
        if storage.present.contains(offset) {
          if let current = run {
            missing.append(current)
            run = nil
          }
        } else {
          run = run.map { $0.lowerBound ..< offset + 1 } ?? (offset ..< offset + 1)
        }
      }
      if let run { missing.append(run) }
      return missing
    }
  }

  @discardableResult
  func write(_ data: Data, at offset: UInt64) throws -> Range<UInt64> {
    let extent = offset ..< offset + UInt64(data.count)
    if refuseWrite(extent) {
      state.withValue { $0.writes.append(offset ..< offset) }
      throw Failure.writeRefused
    }
    state.withValue { storage in
      for index in 0 ..< data.count { storage.present.insert(offset + UInt64(index)) }
      storage.writes.append(extent)
    }
    return extent
  }

  func read(_ range: Range<UInt64>) throws -> Data {
    guard missingRanges(in: range).isEmpty else { throw Failure.notPresent }
    return Data(repeating: 0x5A, count: range.count)
  }

  func seed(_ range: Range<UInt64>) {
    state.withValue { storage in
      for offset in range { storage.present.insert(offset) }
    }
  }
}

/// An upstream client that answers whatever range it is asked for, and can be
/// told to answer a particular range badly or not at all.
private final class RangeEchoHTTPClient: HTTPClient {
  struct Answer {
    var status: Int
    var headers: [String: String]
    var body: Data
  }

  let totalSize: UInt64
  /// When this returns a value for the asked-for range, it replaces the
  /// well-formed echo. Lets a test make one gap response inadmissible.
  var badAnswerForRange: ((Range<UInt64>) -> Answer?)?
  /// When this returns an error for the asked-for range, the request fails.
  var failureForRange: ((Range<UInt64>) -> HTTPError?)?

  private let log = LockIsolated([String?]())
  var requestedRangeHeaders: [String?] { log.value }
  var callCount: Int { log.value.count }

  init(totalSize: UInt64) { self.totalSize = totalSize }

  func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    let header = req.headers["Range"]
    log.withValue { $0.append(header) }
    guard let asked = Self.parseRangeHeader(header) else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    if let failure = failureForRange?(asked) { return .failure(failure) }
    let answer = badAnswerForRange?(asked) ?? Answer(
      status: 206,
      headers: ["Content-Range": "bytes \(asked.lowerBound)-\(asked.upperBound - 1)/\(totalSize)"],
      body: Data(repeating: 0x5A, count: asked.count)
    )
    // Two chunks, because the real client streams and a decorator that only
    // works for a single chunk would pass a single-chunk test.
    let split = answer.body.count / 2
    for chunk in [Data(answer.body.prefix(split)), Data(answer.body.dropFirst(split))]
    where !chunk.isEmpty {
      if case let .failure(error) = consume(chunk, nil) { return .failure(error) }
    }
    return .success(HTTPResponse(
      request: req,
      url: req.url,
      status: HTTPStatus(rawValue: answer.status) ?? .ok,
      headers: answer.headers,
      mediaType: nil,
      body: nil
    ))
  }

  /// `bytes=<start>-<last>` only; this double is never sent an open range.
  static func parseRangeHeader(_ header: String?) -> Range<UInt64>? {
    guard let spec = header?.split(separator: "=").last else { return nil }
    let bounds = spec.split(separator: "-")
    guard bounds.count == 2,
          let start = UInt64(bounds[0]),
          let last = UInt64(bounds[1]),
          last >= start
    else { return nil }
    return start ..< last + 1
  }
}

// MARK: - A transient store failure must not disable caching for good

final class PartialArchiveCacheStoreRetryTests: XCTestCase {

  private let archiveURL = HTTPURL(string: "https://storage.googleapis.com/bucket/book.lcpa")!
  private let archiveLength: UInt64 = 1_630_000_000
  private let retryInterval: TimeInterval = 30

  private struct TransientDiskError: Error {}

  private func request(range: Range<UInt64>) -> HTTPRequest {
    var req = HTTPRequest(url: archiveURL)
    req.setRange(range)
    return req
  }

  @discardableResult
  private func read(
    _ client: PartialArchiveCachingHTTPClient,
    _ range: Range<UInt64>
  ) async -> (ok: Bool, bytes: Int) {
    var received = Data()
    let result = await client.stream(request: request(range: range)) { chunk, _ in
      received.append(chunk)
      return .success(())
    }
    switch result {
    case .success: return (true, received.count)
    case .failure: return (false, received.count)
    }
  }

  /// Builds a client whose store factory throws the first `failures` times.
  private func makeClient(
    upstream: HTTPClient,
    store: ControllableRangeStore,
    failures: Int,
    clock: LockIsolated<TimeInterval>
  ) -> (PartialArchiveCachingHTTPClient, () -> Int) {
    let attempts = LockIsolated(0)
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, _ in
        let attempt = attempts.withValue { value -> Int in
          value += 1
          return value
        }
        if attempt <= failures { throw TransientDiskError() }
        return store
      },
      storeRetryInterval: retryInterval,
      monotonicNow: { clock.value }
    )
    return (client, { attempts.value })
  }

  private func awaitWrites(
    _ store: ControllableRangeStore,
    count: Int,
    timeout: TimeInterval = 2
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while store.writes.count < count, Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// A momentary disk error must not cost the patron the cache for the rest of
  /// the session: once the retry interval has passed the archive is cached
  /// again, so re-reading a window costs nothing at the origin.
  ///
  /// This is the defect the patron feels. Every later chapter window refetches
  /// 6 MB from the origin after one transient failure, which on a 4.3 MB/s link
  /// is seconds of frozen playback per chapter.
  func testATransientStoreFailure_cachingResumesAfterTheRetryInterval() async {
    let window: Range<UInt64> = 0 ..< 100_000
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    let store = ControllableRangeStore(totalSize: archiveLength)
    let clock = LockIsolated<TimeInterval>(1000)
    let (client, _) = makeClient(upstream: upstream, store: store, failures: 1, clock: clock)

    // The read that hits the transient failure. It still succeeds, uncached.
    let first = await read(client, window)
    XCTAssertTrue(first.ok, "a store that cannot be opened must not fail the read")
    XCTAssertEqual(first.bytes, window.count)

    clock.value += retryInterval

    // The store opens this time, so the window is fetched and kept.
    let second = await read(client, window)
    XCTAssertTrue(second.ok)
    XCTAssertEqual(second.bytes, window.count)
    await awaitWrites(store, count: 1)

    let callsBeforeReread = upstream.callCount
    let third = await read(client, window)

    XCTAssertTrue(third.ok)
    XCTAssertEqual(third.bytes, window.count, "the window is answered in full from the store")
    XCTAssertEqual(
      upstream.callCount,
      callsBeforeReread,
      "after the retry interval the archive is cached again, so a re-read must not reach the origin"
    )
  }

  /// The retry is bounded, not per request: a store that is genuinely
  /// unavailable must not be reopened on every 6 MB window read, because each
  /// attempt is blocking file I/O in front of the patron's audio.
  func testAStoreFailure_isNotRetriedOnEveryRequest() async {
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    let store = ControllableRangeStore(totalSize: archiveLength)
    let clock = LockIsolated<TimeInterval>(1000)
    let (client, attempts) = makeClient(
      upstream: upstream, store: store, failures: .max, clock: clock
    )

    await read(client, 0 ..< 100_000)
    clock.value += retryInterval / 3
    await read(client, 200_000 ..< 300_000)
    clock.value += retryInterval / 3
    await read(client, 400_000 ..< 500_000)

    XCTAssertEqual(
      attempts(),
      1,
      "three reads inside one retry interval must cost one open attempt, not three"
    )
  }

  /// And the bound is per archive: a failure on one book must not disable the
  /// cache for another one opened in the same session.
  func testAStoreFailure_doesNotDisableCachingForADifferentArchive() async {
    let otherURL = HTTPURL(string: "https://storage.googleapis.com/bucket/other.lcpa")!
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    let store = ControllableRangeStore(totalSize: archiveLength)
    let clock = LockIsolated<TimeInterval>(1000)
    let attempts = LockIsolated(0)
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { url, _ in
        attempts.withValue { $0 += 1 }
        if url.string == self.archiveURL.string { throw TransientDiskError() }
        return store
      },
      storeRetryInterval: retryInterval,
      monotonicNow: { clock.value }
    )

    let window: Range<UInt64> = 0 ..< 100_000
    await read(client, window)

    var otherRequest = HTTPRequest(url: otherURL)
    otherRequest.setRange(window)
    var received = Data()
    _ = await client.stream(request: otherRequest) { chunk, _ in
      received.append(chunk)
      return .success(())
    }
    await awaitWrites(store, count: 1)

    XCTAssertEqual(
      store.writes,
      [window],
      "the second archive's store opened and kept its bytes"
    )
  }
}

// MARK: - A gap-fill fallback must keep the bytes it fetched

final class PartialArchiveCacheGapFallbackTests: XCTestCase {

  private let archiveURL = HTTPURL(string: "https://storage.googleapis.com/bucket/book.lcpa")!
  private let archiveLength: UInt64 = 1_630_000_000

  /// Mostly-present window: one 10,000-byte gap at the leading edge of a
  /// 100,000-byte window, which is the shape `decide` routes to `fillGaps`.
  private let window: Range<UInt64> = 0 ..< 100_000
  private var gap: Range<UInt64> { 0 ..< 10_000 }

  private func request(range: Range<UInt64>) -> HTTPRequest {
    var req = HTTPRequest(url: archiveURL)
    req.setRange(range)
    return req
  }

  @discardableResult
  private func read(
    _ client: PartialArchiveCachingHTTPClient,
    _ range: Range<UInt64>
  ) async -> (response: HTTPResponse?, bytes: Int) {
    var received = Data()
    let result = await client.stream(request: request(range: range)) { chunk, _ in
      received.append(chunk)
      return .success(())
    }
    switch result {
    case let .success(response): return (response, received.count)
    case .failure: return (nil, received.count)
    }
  }

  private func makeClient(
    upstream: HTTPClient,
    store: ControllableRangeStore
  ) -> PartialArchiveCachingHTTPClient {
    PartialArchiveCachingHTTPClient(upstream: upstream, storeFactory: { _, _ in store })
  }

  /// A gap fetch that fails sends the whole window to the origin — and those
  /// bytes must be kept, or the next read of the window pays for them again.
  func testAFailedGapFetch_keepsTheWindowItReadThrough() async {
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    let store = ControllableRangeStore(totalSize: archiveLength)
    store.seed(gap.upperBound ..< window.upperBound)
    let client = makeClient(upstream: upstream, store: store)
    let failingGap = gap
    upstream.failureForRange = { asked in asked == failingGap ? HTTPError.offline(nil) : nil }

    let first = await read(client, window)
    XCTAssertEqual(first.bytes, window.count, "the caller is still answered in full")
    XCTAssertNotNil(first.response)
    await awaitWrites(store, count: 1)

    let callsBeforeReread = upstream.callCount
    let second = await read(client, window)

    XCTAssertEqual(second.bytes, window.count)
    XCTAssertEqual(
      upstream.callCount,
      callsBeforeReread,
      "the window read through after the failed gap must be kept, so a re-read costs nothing"
    )
  }

  /// Same for a gap response the admission rules reject: the whole-window read
  /// that replaces it is a well-formed 206 and must be stored.
  func testAnInadmissibleGapResponse_keepsTheWindowItReadThrough() async {
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    let store = ControllableRangeStore(totalSize: archiveLength)
    store.seed(gap.upperBound ..< window.upperBound)
    let client = makeClient(upstream: upstream, store: store)
    let badGap = gap
    // A server that ignored `Range` and sent the whole object: 200, no
    // Content-Range. The bytes cannot be placed, so the gap is not admissible.
    upstream.badAnswerForRange = { asked in
      asked == badGap
        ? RangeEchoHTTPClient.Answer(status: 200, headers: [:], body: Data(repeating: 0x01, count: asked.count))
        : nil
    }

    let first = await read(client, window)
    XCTAssertEqual(first.bytes, window.count)
    await awaitWrites(store, count: 1)

    let callsBeforeReread = upstream.callCount
    let second = await read(client, window)

    XCTAssertEqual(second.bytes, window.count)
    XCTAssertEqual(
      upstream.callCount,
      callsBeforeReread,
      "an inadmissible gap must not cost the window twice"
    )
  }

  /// A gap whose write did not land leaves the window un-whole, so it is read
  /// through. That read is a complete, admissible window and must be kept.
  func testAWindowStillNotWholeAfterFilling_keepsTheWindowItReadThrough() async {
    let gapExtent = gap
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    // Only the gap-sized write is refused, so the window read through after it
    // still has somewhere to land.
    let store = ControllableRangeStore(
      totalSize: archiveLength,
      refuseWrite: { $0 == gapExtent }
    )
    store.seed(gap.upperBound ..< window.upperBound)
    let client = makeClient(upstream: upstream, store: store)

    let first = await read(client, window)
    XCTAssertEqual(first.bytes, window.count)
    // The refused gap write, then the window read through.
    await awaitWrites(store, count: 2)

    let callsBeforeReread = upstream.callCount
    let second = await read(client, window)

    XCTAssertEqual(second.bytes, window.count)
    XCTAssertEqual(
      upstream.callCount,
      callsBeforeReread,
      "the window read through because it was not whole must be kept"
    )
  }

  /// The fallback must not change what the caller sees: a complete window, and
  /// a 206 naming exactly the range asked for. Readium reads `Content-Range` to
  /// learn the archive's length, so the header has to survive the fallback.
  func testTheFallbackResponse_stillNamesTheRangeTheCallerAskedFor() async {
    let upstream = RangeEchoHTTPClient(totalSize: archiveLength)
    let store = ControllableRangeStore(totalSize: archiveLength)
    store.seed(gap.upperBound ..< window.upperBound)
    let client = makeClient(upstream: upstream, store: store)
    let failingGap = gap
    upstream.failureForRange = { asked in asked == failingGap ? HTTPError.offline(nil) : nil }

    let (response, bytes) = await read(client, window)

    XCTAssertEqual(bytes, window.count)
    XCTAssertEqual(response?.status.rawValue, 206)
    XCTAssertEqual(
      response?.valueForHeader("Content-Range"),
      "bytes \(window.lowerBound)-\(window.upperBound - 1)/\(archiveLength)"
    )
  }

  private func awaitWrites(
    _ store: ControllableRangeStore,
    count: Int,
    timeout: TimeInterval = 2
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while store.writes.count < count, Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
