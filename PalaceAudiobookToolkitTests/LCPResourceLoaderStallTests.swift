//
//  LCPResourceLoaderStallTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-5240: LCP streaming failed tracks at their start with NSURLErrorDomain
//  -1001. That error was the loader's own guard: a fixed 30 s timer armed per
//  loading request, which only ever covered the content-information phase —
//  the resource lookup plus `estimatedLength()`. For a CBC-encrypted LCP
//  resource that length is computed by fetching the last encrypted blocks of
//  the track, a network range request made again for every loading request,
//  because each request resolves a fresh Readium resource. When that fetch
//  took longer than 30 s the guard failed the request while the lookup was
//  still live, AVFoundation failed the item, and the player rebuilt the queue
//  and asked again.
//
//  The byte-reading loop ran in a detached task outside the tracked task, so
//  neither `resourceLoader(_:didCancel:)` nor teardown could stop it.
//
//  These tests drive `LCPResourceLoaderDelegate` through its loading-request
//  seam with a fake Readium publication, so every timing here is scaled to
//  milliseconds by injecting `stallTimeout`.
//

import AVFoundation
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

final class LCPResourceLoaderStallTests: XCTestCase {

  // MARK: - Fixture

  private static let href = "track0.mp3"
  private static let trackURL = URL(string: "readium-lcp://track0/track0.mp3")!

  private var probe: ResourceProbe!
  private var provider: FakeProvider!

  override func setUp() {
    super.setUp()
    probe = ResourceProbe()
    provider = FakeProvider(probe: probe, href: Self.href)
  }

  override func tearDown() {
    probe.releaseAll()
    probe = nil
    provider = nil
    super.tearDown()
  }

  private func makeLoader(stallTimeout: TimeInterval) -> LCPResourceLoaderDelegate {
    LCPResourceLoaderDelegate(provider: provider, stallTimeout: stallTimeout)
  }

  // MARK: - The reported defect

  /// The field failure, at unit scale: the length lookup outlasts the loader's
  /// timer while still in progress. The request must receive the length and
  /// its bytes, not a -1001.
  func testContentInfo_WhenLengthLookupOutlastsStallTimeout_ServesTheLength() async throws {
    probe.length = 4096
    probe.lengthDelay = 0.6
    let loader = makeLoader(stallTimeout: 0.15)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: true,
      range: LCPRequestedRange(offset: 0, length: 2, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success, "an in-progress length lookup must not be failed by a timer")
    XCTAssertEqual(request.contentLength, 4096)
    XCTAssertEqual(request.respondedBytes, 2)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(request.finishCount, 1, "a loading request is finished exactly once")
  }

  /// A length lookup that the transport ends with an error still ends the
  /// request, and it ends it the way it always has: no length, bytes served.
  func testContentInfo_WhenLengthLookupFailsLate_FinishesWithoutLength() async throws {
    probe.length = 4096
    probe.lengthDelay = 0.4
    probe.lengthFails = true
    let loader = makeLoader(stallTimeout: 0.1)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: true,
      range: LCPRequestedRange(offset: 0, length: 2, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertNil(request.contentLength, "a failed lookup reports no length rather than a wrong one")
    XCTAssertEqual(request.contentType, "public.mp3")
  }

  // MARK: - Length is looked up once per track

  /// Every loading request resolves a new Readium resource, and for CBC each
  /// one fetches the track's tail to learn its length. The loader keeps the
  /// answer per track for the life of the publication.
  func testLength_AcrossRequestsForTheSameTrack_IsLookedUpOnce() async throws {
    probe.length = 300_000
    let loader = makeLoader(stallTimeout: 5)

    let info = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: true,
      range: LCPRequestedRange(offset: 0, length: 2, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: info))
    _ = try await info.waitUntilFinished(timeout: 5)

    let toEnd = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 100_000, length: 0, toEnd: true)
    )
    XCTAssertTrue(loader.shouldWait(for: toEnd))
    let outcome = try await toEnd.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(toEnd.respondedBytes, 200_000, "the cached length still bounds a to-end read")
    XCTAssertEqual(probe.lengthLookups, 1)
    XCTAssertGreaterThanOrEqual(probe.resourcesResolved, 2, "precondition: each request resolved its own resource")
  }

  /// Concurrent requests for one track share one lookup rather than racing
  /// their own.
  func testLength_ConcurrentRequestsForTheSameTrack_ShareOneLookup() async throws {
    probe.length = 4096
    probe.lengthDelay = 0.2
    let loader = makeLoader(stallTimeout: 5)
    let requests = (0..<3).map { _ in
      FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    }

    for request in requests {
      XCTAssertTrue(loader.shouldWait(for: request))
    }
    for request in requests {
      let outcome = try await request.waitUntilFinished(timeout: 5)
      XCTAssertEqual(outcome, .success)
      XCTAssertEqual(request.contentLength, 4096)
    }
    XCTAssertEqual(probe.lengthLookups, 1)
  }

  /// A failed lookup is not remembered: the next request asks again.
  func testLength_AfterAFailedLookup_IsLookedUpAgain() async throws {
    probe.length = 4096
    probe.lengthFails = true
    let loader = makeLoader(stallTimeout: 5)

    let first = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    XCTAssertTrue(loader.shouldWait(for: first))
    _ = try await first.waitUntilFinished(timeout: 5)
    XCTAssertNil(first.contentLength)

    probe.lengthFails = false
    let second = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    XCTAssertTrue(loader.shouldWait(for: second))
    _ = try await second.waitUntilFinished(timeout: 5)

    XCTAssertEqual(second.contentLength, 4096)
    XCTAssertEqual(probe.lengthLookups, 2)
  }

  /// `clearCaches()` forgets lengths along with everything else it drops.
  func testLength_AfterClearCaches_IsLookedUpAgain() async throws {
    probe.length = 4096
    let loader = makeLoader(stallTimeout: 5)

    let first = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    XCTAssertTrue(loader.shouldWait(for: first))
    _ = try await first.waitUntilFinished(timeout: 5)

    loader.clearCaches()
    probe.length = 8192

    let second = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    XCTAssertTrue(loader.shouldWait(for: second))
    _ = try await second.waitUntilFinished(timeout: 5)

    XCTAssertEqual(second.contentLength, 8192)
    XCTAssertEqual(probe.lengthLookups, 2)
  }

  // MARK: - Data phase

  /// A read that delivers nothing for longer than the stall timeout ends with
  /// the loader's own typed error instead of leaving AVFoundation waiting.
  func testDataPhase_WhenNoBytesArriveForStallTimeout_FailsAsStalledNotAsNetworkTimeout() async throws {
    probe.length = 4096
    probe.readHangs = true
    let loader = makeLoader(stallTimeout: 0.2)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: 1024, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .failure(domain: "LCPResourceLoader", code: LCPResourceLoaderError.transferStalled.rawValue))
    XCTAssertNotEqual(
      (LCPResourceLoaderError.transferStalled as NSError).code, NSURLErrorTimedOut,
      "AVFoundation keeps only the code; -1001 would read as a network timeout"
    )
    XCTAssertEqual(request.respondedBytes, 0)
  }

  /// The transfer and its stall timer race to answer the same request. Once
  /// the stall has failed it, a late success — and any late bytes — must not
  /// reach AVFoundation: a request is answered once, and an expiry never
  /// reports the good outcome.
  func testFinishOnce_AfterAStallFailure_DropsTheLateSuccessAndItsBytes() {
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: false, range: nil)
    let once = FinishOnce(request)

    once.fail(LCPResourceLoaderError.transferStalled)
    once.respond(with: Data(count: 16))
    once.succeed()

    XCTAssertEqual(request.finishCount, 1)
    XCTAssertEqual(request.outcome, .failure(domain: "LCPResourceLoader", code: LCPResourceLoaderError.transferStalled.rawValue))
    XCTAssertEqual(request.respondedBytes, 0)
  }

  /// The bound is on inactivity, not on the whole transfer: a read that keeps
  /// delivering, chunk by chunk, runs as long as it needs to.
  func testDataPhase_SlowButSteadyTransfer_IsNotCutOff() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk * 6)
    probe.readDelay = 0.08
    let loader = makeLoader(stallTimeout: 0.25)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 6, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success, "six chunks take ~0.5 s, twice the stall timeout, but none stalls")
    XCTAssertEqual(request.respondedBytes, chunk * 6)
  }

  /// A zero-length request that does not ask for data to the end is served
  /// empty; only a to-end request is widened to the track's length.
  func testDataPhase_ZeroLengthRequestNotToEnd_ServesNoBytes() async throws {
    probe.length = 300_000
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 1000, length: 0, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(request.respondedBytes, 0)
    XCTAssertEqual(probe.lengthLookups, 0, "no length is needed for a request that does not read to the end")
  }

  // MARK: - Cancellation

  /// AVFoundation cancels a request it no longer needs. The reader must stop
  /// reading, and must not finish a request AVFoundation has cancelled.
  func testDidCancel_DuringTheDataPhase_StopsTheReader() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk * 8)
    probe.readDelay = 0.05
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 8, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    try await waitUntil(timeout: 5) { request.respondedBytes > 0 }
    loader.didCancel(request)
    let readsAtCancel = probe.reads

    try await Task.sleep(nanoseconds: 600_000_000)

    XCTAssertLessThanOrEqual(probe.reads, readsAtCancel + 1, "at most the read in flight at cancel may complete")
    XCTAssertLessThan(request.respondedBytes, chunk * 8)
    XCTAssertNil(request.outcome, "a cancelled request is AVFoundation's to drop, not ours to finish")
  }

  /// A cancelled request waiting on a length lookup that never returns must
  /// give its concurrency slot back. The loader admits eight requests at a
  /// time; if cancelled requests kept their slots, the ninth would block the
  /// resource-loader queue indefinitely.
  func testDidCancel_WhileLengthLookupHangs_ReleasesTheRequestSlot() async throws {
    probe.length = 4096
    probe.lengthHangs = true
    let loader = makeLoader(stallTimeout: 60)
    let parked = (0..<8).map { _ in
      FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    }
    for request in parked {
      XCTAssertTrue(loader.shouldWait(for: request))
    }
    try await waitUntil(timeout: 5) { self.probe.lengthCallsStarted > 0 }

    for request in parked {
      loader.didCancel(request)
    }

    let otherProbe = ResourceProbe()
    otherProbe.length = 2048
    provider.addTrack(href: "track1.mp3", probe: otherProbe)
    let next = FakeLoadingRequest(
      url: URL(string: "readium-lcp://track1/track1.mp3")!,
      needsContentInformation: true,
      range: nil
    )
    let admitted = expectation(description: "ninth request admitted")
    DispatchQueue.global().async {
      _ = loader.shouldWait(for: next)
      admitted.fulfill()
    }
    await fulfillment(of: [admitted], timeout: 3)

    let outcome = try await next.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(next.contentLength, 2048)
    for request in parked {
      XCTAssertNil(request.outcome, "cancelled requests are not finished by the loader")
    }
  }

  /// Teardown stops every transfer, including ones AVFoundation never cancelled.
  func testCancelAllRequests_StopsEveryTransfer() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk * 8)
    probe.readDelay = 0.05
    let loader = makeLoader(stallTimeout: 5)
    let requests = (0..<2).map { _ in
      FakeLoadingRequest(
        url: Self.trackURL,
        needsContentInformation: false,
        range: LCPRequestedRange(offset: 0, length: chunk * 8, toEnd: false)
      )
    }

    for request in requests {
      XCTAssertTrue(loader.shouldWait(for: request))
    }
    try await waitUntil(timeout: 5) { requests.allSatisfy { $0.respondedBytes > 0 } }
    loader.cancelAllRequests()
    let readsAtCancel = probe.reads

    try await Task.sleep(nanoseconds: 600_000_000)

    XCTAssertLessThanOrEqual(probe.reads, readsAtCancel + requests.count)
    for request in requests {
      XCTAssertNil(request.outcome)
    }
  }

  // MARK: - Lifetime

  /// The loader can be released while a request it admitted is still running.
  /// The admission semaphore must be signalled before it is disposed:
  /// libdispatch traps when a semaphore is released below its initial value.
  func testLoader_ReleasedWhileARequestIsInFlight_DoesNotTrap() async throws {
    probe.length = 4096
    probe.lengthDelay = 0.2
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
    var loader: LCPResourceLoaderDelegate? = makeLoader(stallTimeout: 5)
    weak var weakLoader = loader
    XCTAssertEqual(loader?.shouldWait(for: request), true)
    try await waitUntil(timeout: 5) { self.probe.lengthCallsStarted > 0 }
    loader = nil

    let outcome = try await request.waitUntilFinished(timeout: 5)
    try await waitUntil(timeout: 5) { weakLoader == nil }

    XCTAssertEqual(outcome, .success)
  }

  // MARK: - Helpers

  private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline {
        XCTFail("condition not met within \(timeout) s")
        throw CancellationError()
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

// MARK: - Fakes

/// A loading request that records what the loader does to it.
private final class FakeLoadingRequest: LCPStreamingLoadingRequest, @unchecked Sendable {
  enum Outcome: Equatable {
    case success
    case failure(domain: String, code: Int)
  }

  let requestURL: URL?
  let needsContentInformation: Bool
  let requestedRange: LCPRequestedRange?

  private let lock = NSLock()
  private var _contentType: String?
  private var _contentLength: Int64?
  private var _respondedBytes = 0
  private var _outcome: Outcome?
  private var _finishCount = 0

  init(url: URL, needsContentInformation: Bool, range: LCPRequestedRange?) {
    requestURL = url
    self.needsContentInformation = needsContentInformation
    requestedRange = range
  }

  var contentType: String? { lock.withLock { _contentType } }
  var contentLength: Int64? { lock.withLock { _contentLength } }
  var respondedBytes: Int { lock.withLock { _respondedBytes } }
  var outcome: Outcome? { lock.withLock { _outcome } }
  var finishCount: Int { lock.withLock { _finishCount } }

  func provideContentInformation(contentType: String, contentLength: Int64?) {
    lock.withLock {
      _contentType = contentType
      _contentLength = contentLength
    }
  }

  func respond(with data: Data) {
    lock.withLock { _respondedBytes += data.count }
  }

  /// Records the FIRST outcome; later finishes only bump the count, so a
  /// double finish shows up as `finishCount > 1` rather than as a crash.
  func finishLoading() {
    lock.withLock {
      _finishCount += 1
      if _outcome == nil { _outcome = .success }
    }
  }

  func finishLoading(with error: Error?) {
    let nsError = (error ?? NSError(domain: "nil", code: 0)) as NSError
    lock.withLock {
      _finishCount += 1
      if _outcome == nil { _outcome = .failure(domain: nsError.domain, code: nsError.code) }
    }
  }

  func waitUntilFinished(timeout: TimeInterval) async throws -> Outcome {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let outcome { return outcome }
      if Date() > deadline {
        XCTFail("loading request was not finished within \(timeout) s")
        throw CancellationError()
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

/// Configures and counts what the fake resources for one track do. Every
/// resource resolved for the track shares it, which mirrors production: each
/// loading request gets a new Readium resource for the same bytes.
private final class ResourceProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var _length: UInt64 = 0
  private var _lengthDelay: TimeInterval = 0
  private var _lengthFails = false
  private var _lengthHangs = false
  private var _readDelay: TimeInterval = 0
  private var _readHangs = false
  private var _lengthLookups = 0
  private var _lengthCallsStarted = 0
  private var _reads = 0
  private var _resourcesResolved = 0
  private var parked: [CheckedContinuation<Void, Never>] = []
  private var released = false

  var length: UInt64 { get { lock.withLock { _length } } set { lock.withLock { _length = newValue } } }
  var lengthDelay: TimeInterval { get { lock.withLock { _lengthDelay } } set { lock.withLock { _lengthDelay = newValue } } }
  var lengthFails: Bool { get { lock.withLock { _lengthFails } } set { lock.withLock { _lengthFails = newValue } } }
  var lengthHangs: Bool { get { lock.withLock { _lengthHangs } } set { lock.withLock { _lengthHangs = newValue } } }
  var readDelay: TimeInterval { get { lock.withLock { _readDelay } } set { lock.withLock { _readDelay = newValue } } }
  var readHangs: Bool { get { lock.withLock { _readHangs } } set { lock.withLock { _readHangs = newValue } } }
  var lengthLookups: Int { lock.withLock { _lengthLookups } }
  var lengthCallsStarted: Int { lock.withLock { _lengthCallsStarted } }
  var reads: Int { lock.withLock { _reads } }
  var resourcesResolved: Int { lock.withLock { _resourcesResolved } }

  func noteResolved() { lock.withLock { _resourcesResolved += 1 } }

  /// Ends every parked call so no task outlives the test.
  func releaseAll() {
    let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
      released = true
      defer { parked.removeAll() }
      return parked
    }
    waiting.forEach { $0.resume() }
  }

  /// Parks like a lookup stuck below the transport: it ignores task
  /// cancellation, as Readium's CBC length task does.
  private func park() async {
    await withCheckedContinuation { continuation in
      let resumeNow: Bool = lock.withLock {
        if released { return true }
        parked.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  /// Sleeps without observing cancellation, like an in-flight network call.
  private func delay(_ seconds: TimeInterval) async {
    guard seconds > 0 else { return }
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
  }

  func estimatedLength() async -> ReadResult<UInt64?> {
    let (hangs, wait) = lock.withLock { () -> (Bool, TimeInterval) in
      _lengthCallsStarted += 1
      return (_lengthHangs, _lengthDelay)
    }
    if hangs { await park() }
    await delay(wait)
    return lock.withLock {
      _lengthLookups += 1
      if _lengthFails {
        return .failure(.access(.other(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))))
      }
      return .success(_length)
    }
  }

  func read(_ range: Range<UInt64>?) async -> ReadResult<Data> {
    let (hangs, wait, total) = lock.withLock { () -> (Bool, TimeInterval, UInt64) in
      _reads += 1
      return (_readHangs, _readDelay, _length)
    }
    if hangs { await park() }
    await delay(wait)
    let lower = min(range?.lowerBound ?? 0, total)
    let upper = min(range?.upperBound ?? total, total)
    return .success(Data(count: Int(upper - lower)))
  }
}

private final class FakeResource: Resource {
  let probe: ResourceProbe
  init(probe: ResourceProbe) { self.probe = probe }

  let sourceURL: AbsoluteURL? = nil
  func properties() async -> ReadResult<ResourceProperties> { .success(ResourceProperties()) }
  func estimatedLength() async -> ReadResult<UInt64?> { await probe.estimatedLength() }
  func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
    switch await probe.read(range) {
    case let .success(data):
      consume(data)
      return .success(())
    case let .failure(error):
      return .failure(error)
    }
  }
}

private final class FakeContainer: Container, @unchecked Sendable {
  private let lock = NSLock()
  private var probes: [String: ResourceProbe] = [:]

  func add(href: String, probe: ResourceProbe) { lock.withLock { probes[href] = probe } }

  let sourceURL: AbsoluteURL? = nil
  var entries: Set<AnyURL> { [] }

  subscript(url: any URLConvertible) -> Resource? {
    let path = url.anyURL.string
    let probe = lock.withLock { probes.first { path.hasSuffix($0.key) }?.value }
    guard let probe else { return nil }
    probe.noteResolved()
    return FakeResource(probe: probe)
  }
}

private final class FakeProvider: StreamingResourceProvider, @unchecked Sendable {
  private let container = FakeContainer()
  private let lock = NSLock()
  private var hrefs: [String] = []
  private var publication: Publication

  init(probe: ResourceProbe, href: String) {
    container.add(href: href, probe: probe)
    hrefs = [href]
    publication = Self.makePublication(hrefs: hrefs, container: container)
  }

  func addTrack(href: String, probe: ResourceProbe) {
    container.add(href: href, probe: probe)
    lock.withLock {
      hrefs.append(href)
      publication = Self.makePublication(hrefs: hrefs, container: container)
    }
  }

  func getPublication() -> Publication? { lock.withLock { publication } }

  private static func makePublication(hrefs: [String], container: Container) -> Publication {
    Publication(
      manifest: Manifest(
        metadata: Metadata(title: "PP-5240"),
        readingOrder: hrefs.map { Link(href: $0, mediaType: .mp3) }
      ),
      container: container
    )
  }
}
