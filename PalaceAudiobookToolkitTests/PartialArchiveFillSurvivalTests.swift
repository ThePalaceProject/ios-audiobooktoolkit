//
//  PartialArchiveFillSurvivalTests.swift
//  PalaceAudiobookToolkitTests
//
//  A skip burst cancels one range request per tap. These pin that the bytes
//  already paid for survive the cancellation, and that a tap landing inside a
//  window already being fetched waits for it instead of opening a second
//  request for the same bytes (PP-5401).
//

import XCTest
import ReadiumShared
@testable import PalaceAudiobookToolkit

// MARK: - Doubles

/// A store that records what was written and can answer reads from it.
///
/// Byte-exact rather than range-algebraic: a test asserts on the bytes a joiner
/// was served, and a fake that tracked only ranges could not tell a correct
/// serve from a zero-filled one.
private final class RecordingRangeStore: ArchiveRangeStore, @unchecked Sendable {
  let totalSize: UInt64

  private let lock = NSLock()
  private var _bytes: [UInt64: UInt8] = [:]
  private var _writes: [Range<UInt64>] = []

  var writes: [Range<UInt64>] { lock.withLock { _writes } }

  init(totalSize: UInt64) { self.totalSize = totalSize }

  func missingRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
    lock.withLock {
      var missing: [Range<UInt64>] = []
      var run: Range<UInt64>?
      for offset in range {
        if _bytes[offset] == nil {
          run = run.map { $0.lowerBound ..< offset + 1 } ?? (offset ..< offset + 1)
        } else if let open = run {
          missing.append(open)
          run = nil
        }
      }
      if let open = run { missing.append(open) }
      return missing
    }
  }

  @discardableResult
  func write(_ bytes: Data, at offset: UInt64) throws -> Range<UInt64> {
    lock.withLock {
      for (index, byte) in bytes.enumerated() {
        _bytes[offset + UInt64(index)] = byte
      }
      let written = offset ..< offset + UInt64(bytes.count)
      _writes.append(written)
      return written
    }
  }

  func read(_ range: Range<UInt64>) throws -> Data {
    try lock.withLock {
      var out = Data()
      for offset in range {
        guard let byte = _bytes[offset] else {
          throw PartialArchiveStoreError.notPresent(missing: [offset ..< offset + 1])
        }
        out.append(byte)
      }
      return out
    }
  }
}

/// An origin that delivers its first chunk, then holds the response open until
/// the test releases it, the way a slow archive origin does during a download.
///
/// It checks `Task.isCancelled` after the wait, which is what Readium's own
/// client does: so a fetch still running inside the caller's task sees the
/// cancellation and abandons the body, and only a fetch detached from that task
/// goes on to deliver it. That is the distinction these tests turn on.
private final class HeldOpenOriginClient: HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var _callCount = 0
  private var _rangesAsked: [Range<UInt64>?] = []
  private var _observedCancellation = false

  var callCount: Int { lock.withLock { _callCount } }
  var rangesAsked: [Range<UInt64>?] { lock.withLock { _rangesAsked } }
  /// True if any fetch found its task cancelled, i.e. it was not detached.
  var observedCancellation: Bool { lock.withLock { _observedCancellation } }

  /// Signalled once the first chunk of the first call has been delivered.
  let firstChunkOut = XCTestExpectation(description: "first chunk delivered")
  /// Held closed until the test lets the origin finish.
  ///
  /// A polled flag rather than a semaphore: a semaphore wait cannot be
  /// cancelled, so a fetch still tied to its caller would park in it forever
  /// and the test would hang instead of failing. A hang reports as silence.
  private var _released = false
  private var released: Bool { lock.withLock { _released } }

  let totalSize: UInt64
  /// Byte value written for a given offset, so a serve can be checked exactly.
  static func byte(at offset: UInt64) -> UInt8 { UInt8(offset % 251) }

  init(totalSize: UInt64) { self.totalSize = totalSize }

  func release() { lock.withLock { _released = true } }

  func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    let asked = Self.parseRangeHeader(req.headers["Range"])
    lock.withLock {
      _callCount += 1
      _rangesAsked.append(asked)
    }
    guard let asked else { return .failure(HTTPError.malformedResponse(nil)) }

    let body = Data(asked.map { Self.byte(at: $0) })
    let split = body.count / 2
    let first = Data(body.prefix(split))
    let second = Data(body.dropFirst(split))

    if !first.isEmpty, case let .failure(error) = consume(first, nil) {
      return .failure(error)
    }
    firstChunkOut.fulfill()

    // Hold the response open the way a slow origin does, re-checking
    // cancellation so a fetch that is still tied to its caller reports that
    // rather than hanging. The deadline is a backstop against a bug in the
    // test itself parking the whole suite.
    let deadline = Date().addingTimeInterval(10)
    while !released, Date() < deadline {
      if Task.isCancelled {
        lock.withLock { _observedCancellation = true }
        return .failure(HTTPError.cancelled)
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    if Task.isCancelled {
      lock.withLock { _observedCancellation = true }
      return .failure(HTTPError.cancelled)
    }

    if !second.isEmpty, case let .failure(error) = consume(second, nil) {
      return .failure(error)
    }
    return .success(HTTPResponse(
      request: req,
      url: req.url,
      status: HTTPStatus(rawValue: 206) ?? .ok,
      headers: [
        "Content-Range": "bytes \(asked.lowerBound)-\(asked.upperBound - 1)/\(totalSize)",
        "Content-Length": "\(body.count)"
      ],
      mediaType: nil,
      body: nil
    ))
  }

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

// MARK: - Tests

final class PartialArchiveFillSurvivalTests: XCTestCase {

  private let archive = HTTPURL(string: "https://example.invalid/burst.lcpa")!

  private func makeClient(
    upstream: HTTPClient,
    store: ArchiveRangeStore
  ) -> PartialArchiveCachingHTTPClient {
    PartialArchiveCachingHTTPClient(upstream: upstream, storeFactory: { _, _ in store })
  }

  private func request(_ range: Range<UInt64>) -> HTTPRequest {
    var req = HTTPRequest(url: archive)
    req.setRange(range)
    return req
  }

  /// A tap that cancels its request must not throw away the bytes the origin
  /// was already paid for.
  ///
  /// This is the egress half of the skip burst: 48 of 97 serves in the device
  /// run were cancelled, and a fetch abandoned mid-body stored nothing, so the
  /// next tap started a fresh fetch of the same window.
  func test_whenTheCallerIsCancelled_theWindowStillReachesTheStore() async {
    let total: UInt64 = 8192
    let window: Range<UInt64> = 0 ..< 4096
    let store = RecordingRangeStore(totalSize: total)
    let origin = HeldOpenOriginClient(totalSize: total)
    let client = makeClient(upstream: origin, store: store)

    let caller = Task {
      await client.stream(request: request(window)) { _, _ in .success(()) }
    }

    await fulfillment(of: [origin.firstChunkOut], timeout: 5)
    caller.cancel()
    origin.release()
    _ = await caller.value

    // The fill has to be allowed to finish and commit after the caller is gone.
    let committed = await poll(timeout: 5) {
      store.writes.contains { $0.lowerBound <= window.lowerBound && $0.upperBound >= window.upperBound }
    }

    XCTAssertFalse(
      origin.observedCancellation,
      "the origin fetch must outlive the caller's cancellation, or its bytes are lost"
    )
    XCTAssertTrue(
      committed,
      "the cancelled caller's window must still be committed; writes were \(store.writes)"
    )
  }

  /// A tap landing inside a window already being fetched must wait for that
  /// fetch, not open a second request for bytes already in flight.
  ///
  /// This is the freeze half: taps arrive every 0.2-0.3s while a fill needs
  /// 2-5s for its first byte, so without joining no fetch ever completes.
  func test_aRequestInsideAWindowBeingFetched_joinsItInsteadOfRefetching() async {
    let total: UInt64 = 8192
    let window: Range<UInt64> = 0 ..< 4096
    let inside: Range<UInt64> = 1024 ..< 2048
    let store = RecordingRangeStore(totalSize: total)
    let origin = HeldOpenOriginClient(totalSize: total)
    let client = makeClient(upstream: origin, store: store)

    let first = Task {
      await client.stream(request: request(window)) { _, _ in .success(()) }
    }
    await fulfillment(of: [origin.firstChunkOut], timeout: 5)

    let servedToJoiner = ByteSink()
    let second = Task {
      await client.stream(request: self.request(inside)) { data, _ in
        servedToJoiner.append(data)
        return .success(())
      }
    }

    // Give the joiner a moment to reach its decision while the first fill is
    // still open, which is the state this test is about.
    try? await Task.sleep(nanoseconds: 200_000_000)
    origin.release()

    _ = await first.value
    let joinerResult = await second.value

    XCTAssertEqual(
      origin.callCount, 1,
      "a tap inside a window already in flight must not open a second origin request; asked \(origin.rangesAsked)"
    )
    guard case .success = joinerResult else {
      return XCTFail("the joiner must be served, got \(joinerResult)")
    }
    XCTAssertEqual(
      servedToJoiner.data,
      Data(inside.map { HeldOpenOriginClient.byte(at: $0) }),
      "the joiner must receive exactly its own sub-range, from the store"
    )
  }

  /// The tap that started a fill being cancelled must not wake the taps waiting
  /// on it.
  ///
  /// This is the burst's own shape: tap 1 opens the window and is cancelled by
  /// tap 2, which is waiting for that same window. Releasing a joiner when the
  /// originator goes away sends it to read a window that has not been committed
  /// yet, so it fetches the window again — which is the cost joining exists to
  /// remove. Written after an implementation that passed both other tests while
  /// doing exactly this.
  func test_cancellingTheOriginatingRequest_doesNotWakeAJoinerEarly() async {
    let total: UInt64 = 8192
    let window: Range<UInt64> = 0 ..< 4096
    let inside: Range<UInt64> = 1024 ..< 2048
    let store = RecordingRangeStore(totalSize: total)
    let origin = HeldOpenOriginClient(totalSize: total)
    let client = makeClient(upstream: origin, store: store)

    let originator = Task {
      await client.stream(request: request(window)) { _, _ in .success(()) }
    }
    await fulfillment(of: [origin.firstChunkOut], timeout: 5)

    let servedToJoiner = ByteSink()
    let joiner = Task {
      await client.stream(request: self.request(inside)) { data, _ in
        servedToJoiner.append(data)
        return .success(())
      }
    }
    // Let the joiner reach its wait before the originator disappears.
    try? await Task.sleep(nanoseconds: 200_000_000)

    originator.cancel()
    _ = await originator.value

    // The joiner must still be waiting on the fill, not off fetching its own
    // copy: the origin has been asked exactly once and is still held open.
    XCTAssertEqual(
      origin.callCount, 1,
      "the joiner must wait for the fill rather than refetch when the originator is cancelled; asked \(origin.rangesAsked)"
    )

    origin.release()
    let joinerResult = await joiner.value

    XCTAssertEqual(
      origin.callCount, 1,
      "one window, one origin request, however the originating tap ended; asked \(origin.rangesAsked)"
    )
    guard case .success = joinerResult else {
      return XCTFail("the joiner must be served from the completed fill, got \(joinerResult)")
    }
    XCTAssertEqual(
      servedToJoiner.data,
      Data(inside.map { HeldOpenOriginClient.byte(at: $0) }),
      "the joiner must receive its own sub-range from the store"
    )
  }

  // MARK: - What counts as inside the window

  /// A request starting exactly where the window starts is inside it.
  ///
  /// The three tests here pin the containment predicate one boundary at a time.
  /// Written because a mutation run turned `<=` into `<`, `>=` into `>`, and
  /// `&&` into `||` on that predicate and nothing failed: the first tests all
  /// used a sub-range strictly inside the window, so no boundary was ever
  /// exercised.
  func test_aRequestStartingAtTheWindowsStart_joinsIt() async {
    await expectJoin(window: 0 ..< 4096, request: 0 ..< 2048, joins: true)
  }

  /// A request ending exactly where the window ends is inside it.
  func test_aRequestEndingAtTheWindowsEnd_joinsIt() async {
    await expectJoin(window: 0 ..< 4096, request: 2048 ..< 4096, joins: true)
  }

  /// A request running past the window is NOT inside it, and must not wait for
  /// a fill that was never going to produce its tail.
  func test_aRequestExtendingPastTheWindow_doesNotJoinIt() async {
    await expectJoin(window: 0 ..< 4096, request: 2048 ..< 6000, joins: false)
  }

  /// Drives one fill, issues `request` while it is still open, and checks
  /// whether that request waited for the fill or went to the origin itself.
  ///
  /// Keyed on whether a second origin request is made WHILE the first fill is
  /// still held open. That is observable immediately and needs no timing
  /// assumption: a joiner cannot have asked the origin, and a non-joiner must
  /// have.
  private func expectJoin(
    window: Range<UInt64>,
    request wanted: Range<UInt64>,
    joins: Bool
  ) async {
    let store = RecordingRangeStore(totalSize: 8192)
    let origin = HeldOpenOriginClient(totalSize: 8192)
    let client = makeClient(upstream: origin, store: store)

    let first = Task {
      await client.stream(request: request(window)) { _, _ in .success(()) }
    }
    await fulfillment(of: [origin.firstChunkOut], timeout: 5)

    let second = Task {
      await client.stream(request: self.request(wanted)) { _, _ in .success(()) }
    }

    let askedTwice = await poll(timeout: 2) { origin.callCount >= 2 }
    if joins {
      XCTAssertFalse(
        askedTwice,
        "\(wanted) is inside \(window) and must wait for that fill; the origin was asked \(origin.rangesAsked)"
      )
    } else {
      XCTAssertTrue(
        askedTwice,
        "\(wanted) runs past \(window) and must fetch its own bytes rather than wait; the origin was asked \(origin.rangesAsked)"
      )
    }

    origin.release()
    _ = await first.value
    _ = await second.value
  }

  // MARK: - Helpers

  /// Polls a condition the store's serial commit queue satisfies asynchronously.
  /// A deadline, not a fixed sleep: the commit is two `F_FULLFSYNC`s behind a
  /// queue, and a sleep long enough to be safe on a loaded machine would be
  /// most of a second on every run.
  private func poll(timeout: TimeInterval, until condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }
}

/// Collects the bytes handed to a `consume` closure from several threads.
private final class ByteSink: @unchecked Sendable {
  private let lock = NSLock()
  private var _data = Data()
  var data: Data { lock.withLock { _data } }
  func append(_ chunk: Data) { lock.withLock { _data.append(chunk) } }
}
