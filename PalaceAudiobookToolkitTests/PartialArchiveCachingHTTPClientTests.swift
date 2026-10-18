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
  /// When set, the answer is built from the range the request asked for,
  /// so a test can tell a gap fetch from a whole-window refetch.
  var answerForRange: ((Range<UInt64>) -> Answer)?
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
    let header = req.headers["Range"]
    requestedRangeHeaders.append(header)
    if let answerForRange, let asked = Self.parseRangeHeader(header) {
      answer = answerForRange(asked)
    }
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

  /// A window that is mostly local costs its gaps.
  ///
  /// This is the cold-chapter-open shape: Readium's 6 MB archive window shifted
  /// 122,880 bytes backwards for AVFoundation's tail probe, so nearly all of
  /// what it asks for was fetched by the read before it.
  func test_decide_mostlyPresent_fillsTheGaps() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [1024 ..< 2048],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .fillGaps(requested: 0 ..< 6_291_456, missing: [1024 ..< 2048])
    )
  }

  /// Each gap is its own round trip, so a window broken into more pieces than
  /// the cap is cheaper to refetch whole than to stitch.
  func test_decide_partlyPresentButTooFragmented_fetchesTheWholeWindow() {
    let gaps: [Range<UInt64>] = [
      0 ..< 1024, 2048 ..< 3072, 4096 ..< 5120, 6144 ..< 7168, 8192 ..< 9216
    ]
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: gaps,
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true,
        maxGapRequestsPerRead: 4
      ),
      .fetchAndStore(0 ..< 6_291_456)
    )
  }

  /// A saving that does not at least halve the bytes does not pay for the extra
  /// round trip.
  func test_decide_partlyPresentWithLittleSaving_fetchesTheWholeWindow() {
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [0 ..< 4_000_000],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .fetchAndStore(0 ..< 6_291_456)
    )
  }

  /// Exactly half missing is the boundary, and it fills rather than refetching:
  /// the comparison is `<=`, so the cheaper path is taken on the tie.
  func test_decide_exactlyHalfMissing_fillsTheGaps() {
    let half: Range<UInt64> = 0 ..< 3_145_728
    XCTAssertEqual(
      Client.decide(
        isRangedGET: true,
        requested: 0 ..< 6_291_456,
        missing: [half],
        maxCacheableRangeLength: 8 * 1024 * 1024,
        hasCacheSlot: true
      ),
      .fillGaps(requested: 0 ..< 6_291_456, missing: [half])
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

  /// The store is asked for on the way in, and opened from the length the first
  /// response reports when nothing is on disk yet.
  ///
  /// Both calls matter. The first carries no length and is what lets a book read
  /// before be served from disk without a round trip; the second carries the
  /// length from `Content-Range` and is what opens a store for a book being read
  /// for the first time. Nothing knows the archive's size before that response,
  /// so the order is not negotiable.
  func testTheStore_isAskedForWithoutALength_thenOpenedFromTheResponse() async {
    let range: Range<UInt64> = 0 ..< 131_072
    let upstream = ScriptedHTTPClient(answer: partialAnswer(for: range))
    let store = FakeRangeStore(totalSize: archiveLength)
    var openedWith: [UInt64?] = []
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, totalSize in
        openedWith.append(totalSize)
        // Nothing on disk for this archive yet, so decline until a length is known.
        return totalSize == nil ? nil : store
      }
    )

    _ = await collect(client, request(range: range))

    XCTAssertEqual(
      openedWith,
      [nil, archiveLength],
      "asked without a length first, then opened with the one Content-Range reported"
    )
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

// MARK: - The cold chapter open, as a sequence

/// The cold-chapter-open geometry, driven as the sequence AVFoundation actually
/// issues, against the real store.
///
/// `LCPStreamingEgressTests` measures three 6 MB archive fills, 18,874,368
/// bytes, before the first audio sample of a cold chapter. Two of them sit
/// 122,880 bytes apart at the end of the same entry: the content-information
/// read resolves the plaintext length from the final block, and AVFoundation's
/// tail probe then reads 128 kB from the end, which starts behind the window
/// Readium just filled. So 6,168,576 of the second fill's 6,291,456 bytes are
/// bytes the first fill already fetched and this client already stored.
final class PartialArchiveCachingGapFillTests: XCTestCase {

  private let archiveURL = HTTPURL(string: "https://storage.googleapis.com/bucket/book.lcpa")!
  private let archiveLength: UInt64 = 1_630_000_000

  /// Measured, from `testColdChapterOpen_BytesBeforeTheFirstSampleIsServed`.
  private let contentInformationFill: Range<UInt64> = 96_460_800 ..< 102_752_256
  private let tailProbeFill: Range<UInt64> = 96_337_920 ..< 102_629_376

  private var directory: URL!
  private var store: PartialArchiveStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("gapfill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try PartialArchiveStore.open(directory: directory, totalSize: archiveLength)
  }

  override func tearDownWithError() throws {
    store?.close()
    store = nil
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try super.tearDownWithError()
  }

  private func request(range: Range<UInt64>) -> HTTPRequest {
    var req = HTTPRequest(url: archiveURL)
    req.setRange(range)
    return req
  }

  /// Answers exactly what it is asked for, so what the caller receives
  /// identifies which part of a window came from where.
  private func upstreamAnsweringItsRange() -> ScriptedHTTPClient {
    let client = ScriptedHTTPClient(answer: ScriptedHTTPClient.Answer(
      status: 206, headers: [:], body: Data()
    ))
    let length = archiveLength
    client.answerForRange = { asked in
      ScriptedHTTPClient.Answer(
        status: 206,
        headers: ["Content-Range": "bytes \(asked.lowerBound)-\(asked.upperBound - 1)/\(length)"],
        body: Data(repeating: 0x5A, count: asked.count)
      )
    }
    return client
  }

  private func makeClient(_ upstream: ScriptedHTTPClient) -> PartialArchiveCachingHTTPClient {
    PartialArchiveCachingHTTPClient(upstream: upstream, storeFactory: { [store] _, _ in store! })
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
    return (result.isSuccess, received.count)
  }

  /// The tail probe must cost the bytes the first fill missed, not a second
  /// complete fill.
  ///
  /// This is the cost the patron feels: every full fill in front of the first
  /// sample is a second spent watching a frozen 0:00, and on the device
  /// measurement a 6 MB fill took a 5.2 s median.
  func testColdChapterOpen_TailProbeFetchesOnlyWhatTheFirstFillMissed() async {
    let upstream = upstreamAnsweringItsRange()
    let client = makeClient(upstream)

    let first = await read(client, contentInformationFill)
    XCTAssertTrue(first.ok, "the content-information read must succeed")
    XCTAssertEqual(first.bytes, contentInformationFill.count)

    let second = await read(client, tailProbeFill)
    XCTAssertTrue(second.ok, "the tail probe must succeed")
    XCTAssertEqual(
      second.bytes,
      tailProbeFill.count,
      "the caller is still answered in full, from the store and the origin together"
    )

    let gap = tailProbeFill.lowerBound ..< contentInformationFill.lowerBound
    XCTAssertEqual(
      upstream.requestedRangeHeaders,
      [
        "bytes=\(contentInformationFill.lowerBound)-\(contentInformationFill.upperBound - 1)",
        "bytes=\(gap.lowerBound)-\(gap.upperBound - 1)"
      ],
      """
      the tail probe may fetch only the 122,880 bytes the first fill did not \
      cover; refetching its window costs a second complete 6 MB fill in front \
      of the first audio sample
      """
    )
  }

  /// A window read twice in one session costs nothing the second time. This
  /// already held before gap filling, and is kept so the change cannot regress
  /// a fully present window into a fetch.
  func testWindowReadTwice_FetchesNothingTheSecondTime() async {
    let upstream = upstreamAnsweringItsRange()
    let client = makeClient(upstream)

    await read(client, tailProbeFill)
    let again = await read(client, tailProbeFill)

    XCTAssertTrue(again.ok)
    XCTAssertEqual(again.bytes, tailProbeFill.count)
    XCTAssertEqual(
      upstream.requestedRangeHeaders.count,
      1,
      "the second read of the same window must not reach the origin"
    )
  }

  /// A window with nothing local is unchanged: one fetch for the whole thing.
  func testWindowWithNothingLocal_FetchesTheWholeWindow() async {
    let upstream = upstreamAnsweringItsRange()
    let client = makeClient(upstream)

    let only = await read(client, tailProbeFill)

    XCTAssertTrue(only.ok)
    XCTAssertEqual(only.bytes, tailProbeFill.count)
    XCTAssertEqual(
      upstream.requestedRangeHeaders,
      ["bytes=\(tailProbeFill.lowerBound)-\(tailProbeFill.upperBound - 1)"]
    )
  }

  /// A book read before is served from disk on its FIRST read, not after a round
  /// trip.
  ///
  /// The client learns an archive's length from a response's `Content-Range`, so
  /// unless the store is consulted on the way in, the first read of every book
  /// open pays a full 6 MB fill for bytes already on disk. The store directory
  /// outlives the process; a client instance does not.
  func testFirstReadOfAnArchiveAlreadyOnDisk_FetchesNothing() async throws {
    try store.write(
      Data(repeating: 0x5A, count: tailProbeFill.count),
      at: tailProbeFill.lowerBound
    )
    let upstream = upstreamAnsweringItsRange()
    let client = makeClient(upstream)

    let only = await read(client, tailProbeFill)

    XCTAssertTrue(only.ok)
    XCTAssertEqual(only.bytes, tailProbeFill.count, "answered in full from the store")
    XCTAssertEqual(
      upstream.requestedRangeHeaders,
      [],
      "a window already on disk must not be fetched to discover how long the archive is"
    )
  }

}
