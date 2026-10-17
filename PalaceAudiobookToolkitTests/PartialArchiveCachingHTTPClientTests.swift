//
//  PartialArchiveCachingHTTPClientTests.swift
//  PalaceAudiobookToolkitTests
//
//  The bytes Readium reads of a remote LCP archive are kept rather than
//  discarded, and a response that did not honour Range is never written
//  (PP-5367).
//

import Foundation
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

// MARK: - Doubles

/// A byte-range store in memory, with the same whole-range-or-throw read
/// contract as the real one.
private final class FakeRangeStore: ArchiveRangeStore {
  enum Failure: Error, Equatable {
    case notPresent(missing: [Range<UInt64>])
    case outOfSpace(committed: UInt64)
  }

  let totalSize: UInt64
  /// Offsets present, as a set so the fake needs no interval algebra of its own.
  private(set) var bytes: [UInt64: UInt8] = [:]
  private(set) var writes: [Range<UInt64>] = []
  /// When set, a write commits only this many bytes and then throws.
  var commitLimitPerWrite: Int?

  init(totalSize: UInt64) { self.totalSize = totalSize }

  func missingRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
    var missing: [Range<UInt64>] = []
    var run: Range<UInt64>?
    for offset in range {
      if bytes[offset] == nil {
        run = run.map { $0.lowerBound ..< offset + 1 } ?? (offset ..< offset + 1)
      } else if let current = run {
        missing.append(current)
        run = nil
      }
    }
    if let run { missing.append(run) }
    return missing
  }

  @discardableResult
  func write(_ data: Data, at offset: UInt64) throws -> Range<UInt64> {
    let limit = commitLimitPerWrite ?? data.count
    let committed = min(limit, data.count)
    for index in 0 ..< committed {
      bytes[offset + UInt64(index)] = data[data.startIndex + index]
    }
    let range = offset ..< offset + UInt64(committed)
    writes.append(range)
    if committed < data.count {
      throw Failure.outOfSpace(committed: UInt64(committed))
    }
    return range
  }

  func read(_ range: Range<UInt64>) throws -> Data {
    let missing = missingRanges(in: range)
    guard missing.isEmpty else { throw Failure.notPresent(missing: missing) }
    var out = Data(capacity: range.count)
    for offset in range { out.append(bytes[offset]!) }
    return out
  }

  func seed(_ range: Range<UInt64>, byte: UInt8 = 0xAA) {
    for offset in range { bytes[offset] = byte }
  }
}

/// An upstream client that answers from a script and records what it was asked.
private final class ScriptedHTTPClient: HTTPClient {
  struct Answer {
    var status: Int
    var headers: [String: String]
    var body: Data
  }

  var answer: Answer
  private(set) var requestedRangeHeaders: [String?] = []
  private(set) var callCount = 0

  init(answer: Answer) { self.answer = answer }

  func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    callCount += 1
    requestedRangeHeaders.append(req.headers["Range"])
    // Delivered in two chunks, because the real client does and a decorator
    // that only works for one chunk would pass a single-chunk test.
    let split = answer.body.count / 2
    let first = answer.body.prefix(split)
    let second = answer.body.dropFirst(split)
    for chunk in [Data(first), Data(second)] where !chunk.isEmpty {
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
}

// MARK: - The pure decisions

final class PartialArchiveCachingDecisionTests: XCTestCase {

  private typealias Client = PartialArchiveCachingHTTPClient

  // MARK: Content-Range parsing

  func test_parseContentRange_wellFormed() {
    XCTAssertEqual(
      Client.parseContentRange("bytes 0-6291455/1630000000"),
      Client.ContentRange(start: 0, end: 6_291_455, totalSize: 1_630_000_000)
    )
  }

  func test_parseContentRange_midArchive() {
    XCTAssertEqual(
      Client.parseContentRange("bytes 75497472-81788927/1630000000"),
      Client.ContentRange(start: 75_497_472, end: 81_788_927, totalSize: 1_630_000_000)
    )
  }

  /// A server that does not know the total length says `*`. The range itself
  /// is still usable, so this parses rather than failing.
  func test_parseContentRange_unknownTotal() {
    XCTAssertEqual(
      Client.parseContentRange("bytes 0-99/*"),
      Client.ContentRange(start: 0, end: 99, totalSize: nil)
    )
  }

  /// A header this client cannot read is a header it must not write bytes on.
  func test_parseContentRange_unsatisfiedForm_isNotUnderstood() {
    XCTAssertNil(Client.parseContentRange("bytes */1630000000"))
  }

  func test_parseContentRange_otherUnit_isNotUnderstood() {
    XCTAssertNil(Client.parseContentRange("items 0-99/200"))
  }

  func test_parseContentRange_garbage_isNotUnderstood() {
    XCTAssertNil(Client.parseContentRange("bytes 0-/"))
  }

  func test_parseContentRange_reversedBounds_isNotUnderstood() {
    XCTAssertNil(Client.parseContentRange("bytes 100-50/200"))
  }

  // MARK: Admission

  /// The hazard the feasibility work named: `HTTPResource.stream` only checks
  /// whether fewer bytes arrived than expected, so a server that ignores
  /// `Range` and returns 200 with the whole object reads as success. Writing
  /// that at the requested offset puts the head of the archive in its middle.
  func test_admitResponse_statusOK_isRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 200,
        contentRange: nil,
        requested: 75_497_472 ..< 81_788_928,
        bodyLength: 6_291_456
      ),
      .reject(reason: "status 200 is not a partial response")
    )
  }

  /// Even WITH a plausible header, a 200 is not a partial response.
  func test_admitResponse_statusOKWithAContentRange_isStillRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 200,
        contentRange: "bytes 75497472-81788927/1630000000",
        requested: 75_497_472 ..< 81_788_928,
        bodyLength: 6_291_456
      ),
      .reject(reason: "status 200 is not a partial response")
    )
  }

  func test_admitResponse_partialContentAtTheRequestedOffset_isStored() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 206,
        contentRange: "bytes 75497472-81788927/1630000000",
        requested: 75_497_472 ..< 81_788_928,
        bodyLength: 6_291_456
      ),
      .store(at: 75_497_472)
    )
  }

  /// A server may legitimately return a SHORTER range than asked for. The
  /// bytes are still valid at the offset it names, so they are stored — the
  /// offset is what must match, not the length.
  func test_admitResponse_shorterRangeThanAsked_isStoredAtTheOffsetGiven() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 206,
        contentRange: "bytes 75497472-75628543/1630000000",
        requested: 75_497_472 ..< 81_788_928,
        bodyLength: 131_072
      ),
      .store(at: 75_497_472)
    )
  }

  /// A range starting somewhere else is not the range we asked for, and the
  /// offset we would write it at is the one we asked for.
  func test_admitResponse_differentStartOffset_isRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 206,
        contentRange: "bytes 0-6291455/1630000000",
        requested: 75_497_472 ..< 81_788_928,
        bodyLength: 6_291_456
      ),
      .reject(reason: "Content-Range start does not match the requested offset")
    )
  }

  /// The body must be the length the header claims, or we do not know which
  /// bytes we hold.
  func test_admitResponse_bodyShorterThanTheHeaderClaims_isRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 206,
        contentRange: "bytes 0-6291455/1630000000",
        requested: 0 ..< 6_291_456,
        bodyLength: 1024
      ),
      .reject(reason: "body length does not match Content-Range")
    )
  }

  func test_admitResponse_missingContentRange_isRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 206,
        contentRange: nil,
        requested: 0 ..< 6_291_456,
        bodyLength: 6_291_456
      ),
      .reject(reason: "no Content-Range header")
    )
  }

  func test_admitResponse_unreadableContentRange_isRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 206,
        contentRange: "bytes */1630000000",
        requested: 0 ..< 6_291_456,
        bodyLength: 6_291_456
      ),
      .reject(reason: "Content-Range could not be read")
    )
  }

  func test_admitResponse_serverError_isRejected() {
    XCTAssertEqual(
      Client.admitResponse(
        status: 503,
        contentRange: nil,
        requested: 0 ..< 6_291_456,
        bodyLength: 0
      ),
      .reject(reason: "status 503 is not a partial response")
    )
  }

  // MARK: What to do with a request

  func test_decide_everyByteLocal_servesFromTheStore() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .serveFromStore(0 ..< 6_291_456)
    )
  }

  /// A partly-present range is fetched whole for now. Splitting it into gaps
  /// is the gap-filler's job; what matters here is that it is never served
  /// from a store that does not hold all of it.
  func test_decide_partlyPresent_fetchesAndStores() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [1024 ..< 2048],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .fetchAndStore(0 ..< 6_291_456)
    )
  }

  func test_decide_nothingPresent_fetchesAndStores() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [0 ..< 6_291_456],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .fetchAndStore(0 ..< 6_291_456)
    )
  }

  /// Nothing may be written until the status and header are checked, which
  /// means holding the range in memory. Past the cap that is refused rather
  /// than risked.
  func test_decide_rangeLargerThanTheMemoryCap_passesThrough() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< UInt64(16 * 1024 * 1024),
        missing: [0 ..< UInt64(16 * 1024 * 1024)],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .passThrough(reason: "range is larger than the memory cap for validation")
    )
  }

  /// A fully-local range is served however large it is: nothing is buffered
  /// for validation on that path.
  func test_decide_rangeLargerThanTheCapButFullyLocal_isStillServed() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< UInt64(16 * 1024 * 1024),
        missing: [],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .serveFromStore(0 ..< UInt64(16 * 1024 * 1024))
    )
  }

  func test_decide_withNoCacheSlotFree_passesThrough() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [0 ..< 6_291_456],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: false
      ),
      .passThrough(reason: "too many cacheable requests already in flight")
    )
  }

  /// With no slot free the range is still SERVED locally when it is all
  /// there — serving costs no buffer.
  func test_decide_withNoCacheSlotButFullyLocal_isStillServed() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: false
      ),
      .serveFromStore(0 ..< 6_291_456)
    )
  }

  /// The first request of a session, before any store exists: it has to go to
  /// the origin, and its response is what reveals the archive's length.
  func test_decide_withNoStoreYet_fetchesAndStores() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: nil,
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .fetchAndStore(0 ..< 6_291_456)
    )
  }

  func test_decide_requestWithNoRange_passesThrough() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: nil,
        missing: nil,
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .passThrough(reason: "not a ranged GET")
    )
  }

  func test_decide_nonGET_passesThrough() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: false,
        requested: 0 ..< 1024,
        missing: [0 ..< 1024],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .passThrough(reason: "not a ranged GET")
    )
  }

  func test_decide_emptyRange_passesThrough() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 1024 ..< 1024,
        missing: [],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .passThrough(reason: "not a ranged GET")
    )
  }
}

// MARK: - End to end through the client

final class PartialArchiveCachingHTTPClientTests: XCTestCase {

  private let archiveURL = HTTPURL(string: "https://storage.googleapis.com/bucket/book.lcpa")!
  private let archiveLength: UInt64 = 1_630_000_000

  private func request(range: Range<UInt64>) -> HTTPRequest {
    var req = HTTPRequest(url: archiveURL)
    req.setRange(range)
    return req
  }

  private func partialAnswer(for range: Range<UInt64>, byte: UInt8 = 0x5A) -> ScriptedHTTPClient.Answer {
    ScriptedHTTPClient.Answer(
      status: 206,
      headers: [
        "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(archiveLength)"
      ],
      body: Data(repeating: byte, count: range.count)
    )
  }

  private func makeClient(
    upstream: ScriptedHTTPClient,
    store: FakeRangeStore
  ) -> (PartialArchiveCachingHTTPClient, () -> Int) {
    var opens = 0
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, _ in
        opens += 1
        return store
      }
    )
    return (client, { opens })
  }

  private func collect(
    _ client: PartialArchiveCachingHTTPClient,
    _ request: HTTPRequest
  ) async -> (HTTPResult<HTTPResponse>, Data) {
    var received = Data()
    let result = await client.stream(request: request) { chunk, _ in
      received.append(chunk)
      return .success(())
    }
    return (result, received)
  }

  /// The whole point: a 6 MB fill Readium charges us for is written to the
  /// store rather than discarded, so it becomes download progress.
  func testARangeFetched_isWrittenToTheStore() async {
    let range: Range<UInt64> = 75_497_472 ..< 81_788_928
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let store = FakeRangeStore(totalSize: archiveLength)
    let (client, _) = makeClient(upstream: upstream, store: store)

    let (result, received) = await collect(client, request(range: range))

    XCTAssertTrue(result.isSuccess, "the read must still succeed")
    XCTAssertEqual(received.count, range.count, "every byte reaches the caller")
    XCTAssertEqual(store.writes, [range], "and every byte is kept")
  }

  /// And the second read of the same range costs nothing at the origin. This
  /// is the latency win as well as the egress win.
  func testARangeAlreadyLocal_isServedWithoutTouchingTheOrigin() async {
    let range: Range<UInt64> = 0 ..< 131_072
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let store = FakeRangeStore(totalSize: archiveLength)
    store.seed(range, byte: 0x5A)
    let (client, _) = makeClient(upstream: upstream, store: store)
    // A first request so the store is open.
    _ = await collect(client, request(range: 200_000 ..< 300_000))
    let callsBefore = upstream.callCount

    let (result, received) = await collect(client, request(range: range))

    XCTAssertTrue(result.isSuccess)
    XCTAssertEqual(received, Data(repeating: 0x5A, count: range.count),
                   "the local bytes are what the caller gets")
    XCTAssertEqual(upstream.callCount, callsBefore,
                   "a range already on disk must not be fetched again")
  }

  /// The corruption hazard. A server that ignores `Range` answers 200 with the
  /// whole object; `HTTPResource.stream` reports that as success. Those bytes
  /// must reach the caller — it asked for them — but must never be written at
  /// the requested offset.
  func testAResponseThatIgnoredRange_isNeverWritten() async {
    let range: Range<UInt64> = 75_497_472 ..< 81_788_928
    let upstream = ScriptedHTTPClient(answer: ScriptedHTTPClient.Answer(
      status: 200,
      headers: [:],
      body: Data(repeating: 0x01, count: range.count)
    ))
    let store = FakeRangeStore(totalSize: archiveLength)
    let (client, _) = makeClient(upstream: upstream, store: store)

    let (result, received) = await collect(client, request(range: range))

    XCTAssertTrue(result.isSuccess, "the caller's read still succeeds")
    XCTAssertEqual(received.count, range.count, "and still gets its bytes")
    XCTAssertEqual(store.writes, [],
                   "writing the object's head at an archive offset would corrupt the archive")
  }

  /// Same requirement for a response echoing someone else's range.
  func testAResponseAtTheWrongOffset_isNeverWritten() async {
    let range: Range<UInt64> = 75_497_472 ..< 81_788_928
    let upstream = ScriptedHTTPClient(answer: ScriptedHTTPClient.Answer(
      status: 206,
      headers: ["Content-Range": "bytes 0-6291455/1630000000"],
      body: Data(repeating: 0x02, count: range.count)
    ))
    let store = FakeRangeStore(totalSize: archiveLength)
    let (client, _) = makeClient(upstream: upstream, store: store)

    let (_, received) = await collect(client, request(range: range))

    XCTAssertEqual(received.count, range.count)
    XCTAssertEqual(store.writes, [])
  }

  /// The store is opened lazily, from the length the first response reports,
  /// because nothing knows the archive's size before then.
  func testTheStore_isOpenedFromTheFirstResponsesLength() async {
    let range: Range<UInt64> = 0 ..< 131_072
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let store = FakeRangeStore(totalSize: archiveLength)
    var openedWith: [UInt64] = []
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, totalSize in
        openedWith.append(totalSize)
        return store
      }
    )

    _ = await collect(client, request(range: range))

    XCTAssertEqual(openedWith, [archiveLength],
                   "the length comes from Content-Range, not from a HEAD round trip")
  }

  /// Opened once, not once per request: a second store on the same archive
  /// would be refused the advisory lock.
  func testTheStore_isOpenedOncePerArchive() async {
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: 0 ..< 131_072))
    let store = FakeRangeStore(totalSize: archiveLength)
    var opens = 0
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, _ in
        opens += 1
        return store
      }
    )

    _ = await collect(client, request(range: 0 ..< 131_072))
    upstream.answer = partialAnswer(for: 200_000 ..< 331_072)
    _ = await collect(client, request(range: 200_000 ..< 331_072))

    XCTAssertEqual(opens, 1)
  }

  /// A store that cannot be opened must not take the read down with it: the
  /// request falls back to the origin and the book still plays.
  func testAStoreThatCannotBeOpened_fallsBackToTheOrigin() async {
    struct Nope: Error {}
    let range: Range<UInt64> = 0 ..< 131_072
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, _ in throw Nope() }
    )

    let (result, received) = await collect(client, request(range: range))

    XCTAssertTrue(result.isSuccess)
    XCTAssertEqual(received.count, range.count)
  }

  /// Disk full: the store commits the prefix that reached disk and says so.
  /// The caller still gets every byte, and what was committed stays recorded
  /// so a later read refetches only the tail.
  func testAPartialWrite_keepsWhatReachedDiskAndStillServesTheCaller() async {
    let range: Range<UInt64> = 0 ..< 131_072
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let store = FakeRangeStore(totalSize: archiveLength)
    store.commitLimitPerWrite = 1024
    let (client, _) = makeClient(upstream: upstream, store: store)

    let (result, received) = await collect(client, request(range: range))

    XCTAssertTrue(result.isSuccess, "a full disk must not fail the patron's read")
    XCTAssertEqual(received.count, range.count)
    XCTAssertEqual(store.writes, [0 ..< 1024], "only what reached disk is recorded")
  }

  /// A request with no `Range` is not an archive window read — it is the
  /// whole object — and is passed through untouched.
  func testARequestWithNoRange_isPassedThrough() async {
    let upstream = ScriptedHTTPClient(answer: ScriptedHTTPClient.Answer(
      status: 200,
      headers: [:],
      body: Data(repeating: 0x03, count: 4096)
    ))
    let store = FakeRangeStore(totalSize: archiveLength)
    let (client, _) = makeClient(upstream: upstream, store: store)

    let (result, received) = await collect(client, HTTPRequest(url: archiveURL))

    XCTAssertTrue(result.isSuccess)
    XCTAssertEqual(received.count, 4096)
    XCTAssertEqual(store.writes, [])
  }

  /// A served-from-store response has to look like what the caller asked for,
  /// or Readium's own `received < expected` check misreads it.
  func testAServedRange_reportsPartialContentAndTheRangeItServed() async {
    let range: Range<UInt64> = 0 ..< 131_072
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let store = FakeRangeStore(totalSize: archiveLength)
    store.seed(range)
    let (client, _) = makeClient(upstream: upstream, store: store)
    _ = await collect(client, request(range: 900_000 ..< 1_000_000))

    let (result, _) = await collect(client, request(range: range))

    guard case let .success(response) = result else {
      return XCTFail("expected a response")
    }
    XCTAssertEqual(response.status.rawValue, 206)
    XCTAssertEqual(
      response.valueForHeader("Content-Range"),
      "bytes 0-131071/\(archiveLength)"
    )
  }

  /// An upstream failure stays a failure — the client must not paper over a
  /// dead origin with an empty success.
  func testAnUpstreamFailure_isReported() async {
    final class FailingClient: HTTPClient {
      func stream(
        request: any HTTPRequestConvertible,
        consume _: @escaping (Data, Double?) -> HTTPResult<Void>
      ) async -> HTTPResult<HTTPResponse> {
        .failure(HTTPError.offline(nil))
      }
    }
    let store = FakeRangeStore(totalSize: archiveLength)
    let client = PartialArchiveCachingHTTPClient(
      upstream: FailingClient(),
      storeFactory: { _, _ in store }
    )

    let (result, _) = await collect(client, request(range: 0 ..< 131_072))

    XCTAssertFalse(result.isSuccess)
    XCTAssertEqual(store.writes, [])
  }
}

private extension HTTPResult {
  var isSuccess: Bool {
    switch self {
    case .success: return true
    case .failure: return false
    }
  }
}
