//
//  LCPResourceLoaderStallTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-5240: LCP streaming failed tracks at their start with NSURLErrorDomain
//  -1001. That error was the loader's own guard: a fixed 30 s timer armed per
//  loading request, which only ever covered the content-information phase —
//  the resource lookup plus `estimatedLength()`. For a CBC-encrypted LCP
//  resource that length is computed by fetching the last encrypted blocks of
//  the track, a network range request that must not be made per loading
//  request. When that fetch
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
  private static let otherTrackURL = URL(string: "readium-lcp://track1/track1.mp3")!

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

  /// One segment per buffer, so the reader still takes one underlying read per
  /// 128 KB and the cancellation tests below can observe it stopping between
  /// them. The shipped buffer is far larger — what that costs in egress is
  /// `LCPStreamingEgressTests`, and what it costs in cancellation granularity
  /// is `testDidCancel_AtTheShippedBufferSize_StartsNoFurtherFill`.
  private func makeLoader(stallTimeout: TimeInterval) -> LCPResourceLoaderDelegate {
    LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: stallTimeout,
      perTrackBufferSize: 128 * 1024
    )
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
  /// request, and it ends it the way it always has: successfully, with no length.
  ///
  /// The lookup is held open by the test rather than by a delay, so "late"
  /// means "still pending after the stall timeout has passed" on any machine.
  /// The request asks for content information only: a data range would add
  /// the data phase's own stall timer, which races the read and is covered by
  /// the data-phase tests below.
  func testContentInfo_WhenLengthLookupFailsLate_FinishesWithoutLength() async throws {
    probe.length = 4096
    probe.lengthHangs = true
    probe.lengthFails = true
    let stallTimeout: TimeInterval = 0.1
    let loader = makeLoader(stallTimeout: stallTimeout)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    try await waitUntil(timeout: 30) { self.probe.lengthCallsStarted > 0 }
    // At least five stall timeouts pass while the lookup is pending.
    try await Task.sleep(nanoseconds: UInt64(stallTimeout * 5 * 1_000_000_000))
    XCTAssertNil(request.outcome, "a pending length lookup must not be ended by a timer")

    probe.releaseAll()
    // Hang bound only: the request finishes as soon as the released lookup
    // reports its failure. A 5 s bound was exceeded once on CI (ios-core run
    // 36911638959, 37.7 s); the bound matters only if the request never ends.
    let outcome = try await request.waitUntilFinished(timeout: 30)

    XCTAssertEqual(outcome, .success)
    XCTAssertNil(request.contentLength, "a failed lookup reports no length rather than a wrong one")
    XCTAssertEqual(request.contentType, "public.mp3")
  }

  // MARK: - Length is looked up once per track

  /// Learning a CBC track's length means fetching its tail over the network.
  /// The loader keeps the answer per track for the life of the publication, so
  /// a second request for the same track does not pay for it again.
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
    XCTAssertEqual(
      probe.resourcesResolved,
      1,
      "the track's resource is resolved once and reused; a second would mean the buffer was rebuilt per request"
    )
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
    XCTAssertEqual(
      probe.resourcesResolved,
      1,
      "concurrent requests share one resource, so Readium's lazy tail fetch is first-touched once"
    )
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
    XCTAssertEqual(
      probe.resourcesResolved,
      2,
      "clearCaches drops the buffer, so the second request builds a new one; 1 would mean it outlived the publication"
    )
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
  ///
  /// This is the one test in this file that asserts a stall is NOT detected, so
  /// it is the only one a scheduling delay can fail falsely: every other timing
  /// test here forces a stall, and a late chunk only makes those pass harder.
  /// The margin is therefore deliberately wide. Each gap is 0.25 s against a
  /// 1 s timeout, so the test survives three quarters of a second of jitter per
  /// chunk, while six chunks still take 1.5 s and so outlast the timeout, which
  /// is what makes the assertion about inactivity rather than duration. Keep
  /// the gap well under the timeout and the total above it; do not narrow
  /// either to make the suite faster.
  func testDataPhase_SlowButSteadyTransfer_IsNotCutOff() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk * 6)
    probe.readDelay = 0.25
    let loader = makeLoader(stallTimeout: 1.0)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 6, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success, "six chunks take ~1.5 s, longer than the stall timeout, but no single gap stalls")
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
    XCTAssertEqual(
      probe.lengthLookups,
      1,
      "the buffer's read-ahead clamp needs the track length, so it is resolved for every request — once per track, not once per request"
    )
  }

  /// A length lookup that fails must not leave the track without a buffer for
  /// the life of the publication.
  ///
  /// The failed build is not cached: Readium's buffer keeps whatever length it
  /// is first told, so a buffer built without one would clamp nothing, and the
  /// track would pay an archive fill per read until teardown. Dropping the
  /// entry lets the next request build a working one — observable because two
  /// consecutive reads then cost one underlying fetch instead of two.
  func testLength_AfterAFailedLookup_TheNextRequestRebuildsTheBuffer() async throws {
    probe.length = 65_536
    probe.lengthFails = true
    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: 64 * 1024
    )

    // A CBC read cannot decrypt without the length, so with nothing to supply
    // it this request fails. What matters is that the failure is not cached.
    let failing = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: 1_024, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: failing))
    let failedOutcome = try await failing.waitUntilFinished(timeout: 5)
    XCTAssertNotEqual(failedOutcome, .success)

    probe.lengthFails = false
    let readsBeforeRecovery = probe.reads
    try await serveRange(offset: 0, length: 1_024, on: loader)
    try await serveRange(offset: 1_024, length: 1_024, on: loader)

    XCTAssertEqual(
      probe.reads - readsBeforeRecovery,
      1,
      "the rebuilt buffer serves the second read from memory; 2 would mean the track stayed unbuffered"
    )
  }

  /// Drives one bounded data request to completion and returns the bytes it
  /// was answered with.
  ///
  /// It asserts the request SUCCEEDED. `waitUntilFinished` only throws on a
  /// timeout, so a request finished with an error would otherwise pass here
  /// silently and leave a counter-only test green while every read failed —
  /// which matters most for the unbuffered fallback, whose whole justification
  /// is that the chapter still plays.
  @discardableResult
  private func serveRange(
    offset: Int64,
    length: Int,
    on loader: LCPResourceLoaderDelegate,
    url: URL? = nil
  ) async throws -> Int {
    let request = FakeLoadingRequest(
      url: url ?? Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: offset, length: length, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success, "a served range must succeed, not fail silently")
    return request.respondedBytes
  }

  /// A rebuilt buffer must touch its own resource's length, not rely on the
  /// per-track answer already being cached.
  ///
  /// `lengths` memoizes the ANSWER per href; the lazy tail-fetch task it
  /// stands in for belongs to an INSTANCE. Once the bound evicts a track — and
  /// a book has far more tracks than the bound — the rebuild resolves a fresh
  /// instance, hits the answer cache, and would hand reads a resource whose
  /// lazy var no two of them may first-touch together.
  func testBufferRebuild_TouchesItsOwnResourceLength() async throws {
    probe.length = 65_536
    let other = ResourceProbe()
    other.length = 65_536
    provider.addTrack(href: "track1.mp3", probe: other)
    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: 64 * 1024,
      maxBufferedTracks: 1
    )

    try await serveRange(offset: 0, length: 1_024, on: loader)
    let touchesAfterFirstBuild = probe.lengthCallsStarted

    // Build the other track, which evicts this one at a bound of 1.
    try await serveRange(offset: 0, length: 1_024, on: loader, url: Self.otherTrackURL)
    // Come back: the answer is cached, but the instance is new.
    try await serveRange(offset: 0, length: 1_024, on: loader)

    XCTAssertEqual(
      probe.lengthCallsStarted,
      touchesAfterFirstBuild + 1,
      "the rebuilt instance is touched once by its build; without that a read would do it, racing another read"
    )
  }

  /// A track rebuilt after eviction reads with the length the provider kept,
  /// so its fresh resource never fetches the tail: the rebuild serves bytes
  /// even while that fetch would fail, and costs no second lookup (PP-5398).
  func testLength_WhenARebuiltTracksLengthIsKept_TheRebuildNeedsNoTailFetch() async throws {
    probe.length = 65_536
    let other = ResourceProbe()
    other.length = 65_536
    provider.addTrack(href: "track1.mp3", probe: other)
    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: 64 * 1024,
      maxBufferedTracks: 1
    )

    try await serveRange(offset: 0, length: 1_024, on: loader)
    // The provider keeps the learned length, as the app's provider does.
    provider.store(length: 65_536, forHref: Self.href)
    try await serveRange(offset: 0, length: 1_024, on: loader, url: Self.otherTrackURL)
    let lookupsBeforeRebuild = probe.lengthLookups

    // Rebuild this track while a tail fetch would fail.
    probe.lengthFails = true
    let readsBeforeRebuild = probe.reads
    let first = try await serveRange(offset: 0, length: 1_024, on: loader)
    let second = try await serveRange(offset: 1_024, length: 1_024, on: loader)
    probe.lengthFails = false

    XCTAssertEqual(first, 1_024, "the rebuilt track serves bytes, not an error")
    XCTAssertEqual(second, 1_024, "the rebuilt track serves bytes, not an error")
    XCTAssertEqual(probe.lengthLookups, lookupsBeforeRebuild, "the kept length spares the rebuild its tail fetch")
    XCTAssertEqual(
      probe.reads - readsBeforeRebuild,
      1,
      "the rebuilt buffer serves the second read from memory"
    )
  }

  // MARK: - Track window

  /// A track the patron is not waiting on is held back while others read, and
  /// is still served afterwards.
  ///
  /// The concurrency slot is given back before the data phase, so nothing
  /// bounded how many transfers ran at once and a skip burst left serves for
  /// chapters the player had moved past competing with the one the patron was
  /// waiting for (PP-5398). Holding rather than cancelling is the point: a
  /// cancelled request is left unanswered and the stall watchdog dies with it,
  /// so a wrongly-chosen track would hang instead of failing (PP-5240).
  func testTransferBound_ATrackOutsideTheWindow_IsHeldThenStillServed() async throws {
    let chunk = 128 * 1024
    let probe1 = ResourceProbe()
    let probe2 = ResourceProbe()
    for p in [probe!, probe1, probe2] {
      p.length = UInt64(chunk * 4)
      p.readDelay = 0.05
    }
    provider.addTrack(href: "track1.mp3", probe: probe1)
    provider.addTrack(href: "track2.mp3", probe: probe2)

    // One track at a time, so the tracks outside the window must take the
    // single reading slot in turn.
    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 1,
      maxTransferringTracks: 1,
      maxTransferYield: 10
    )

    func startServe(_ url: URL) -> FakeLoadingRequest {
      let request = FakeLoadingRequest(
        url: url,
        needsContentInformation: false,
        range: LCPRequestedRange(offset: 0, length: chunk * 4, toEnd: false)
      )
      XCTAssertTrue(loader.shouldWait(for: request))
      return request
    }

    let first = startServe(Self.trackURL)
    let second = startServe(Self.otherTrackURL)
    let third = startServe(URL(string: "readium-lcp://track2/track2.mp3")!)

    // The load-bearing half: three tracks were demanded at once and only one
    // ever read. Without this the test passes whether or not the bound fires.
    try await waitUntil(timeout: 10) { first.respondedBytes > 0 }
    XCTAssertEqual(loader.peakTransferringTrackCount, 1,
                   "three tracks were demanded; the bound admits one at a time")

    // Every one is answered. Under cancellation the held ones would never
    // finish, which is the failure PP-5240 records.
    for request in [first, second, third] {
      let outcome = try await request.waitUntilFinished(timeout: 30)
      XCTAssertEqual(outcome, .success,
                     "a held transfer must still be served, not left unanswered")
      XCTAssertEqual(request.respondedBytes, chunk * 4, "and must deliver every byte asked for")
    }
  }

  /// The track the patron is waiting on reads at once, however full the bound is.
  ///
  /// Without the exemption the bound is first-come-first-served, so in a
  /// chapter burst the newcomer held back is the chapter someone is waiting to
  /// hear while the incumbents are read-ahead. The yield here is long enough
  /// that a held transfer could not reach the deadline inside the timeout, so
  /// the test fails if the exemption never fires.
  func testPreferredTrack_WhenEverySlotIsHeld_IsAdmittedAtOnce() async throws {
    let chunk = 128 * 1024
    let probe1 = ResourceProbe()
    probe!.length = UInt64(chunk * 200)
    probe!.readDelay = 0.05
    probe1.length = UInt64(chunk)
    probe1.readDelay = 0
    provider.addTrack(href: "track1.mp3", probe: probe1)

    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 20,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 2,
      maxTransferringTracks: 1,
      maxTransferYield: 10
    )

    // Fill the one slot and keep it filled for the rest of the test.
    let longReader = FakeLoadingRequest(
      url: Self.trackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 200, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: longReader))
    try await waitUntil(timeout: 5) { longReader.respondedBytes > 0 }

    // The patron taps through to the track track1.mp3 serves.
    loader.noteTrack(key: "chapter-2", servesHref: "track1.mp3", readingOrderHref: "track1.mp3")
    loader.markChapterLoadStart(trackKey: "chapter-2")

    let preferred = FakeLoadingRequest(
      url: Self.otherTrackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: preferred))

    // One second against a ten-second yield: delivery this soon can only mean
    // it was admitted rather than held to the deadline.
    try await waitUntil(timeout: 1) { preferred.respondedBytes > 0 }
    XCTAssertEqual(loader.peakTransferringTrackCount, 2,
                   "the preferred track must read alongside the slot holder, not behind it")
  }

  /// The exemption matches a track whose href carries a percent escape.
  ///
  /// The map the player fills is keyed for a different consumer and holds the
  /// percent-DECODED path, while a serve resolves the reading order's own
  /// spelling. Matching the wrong one costs nothing on a fixture named
  /// `track1.mp3`, where both spellings agree, and silently never fires in
  /// production. This is the fixture where they disagree.
  func testPreferredTrack_WithAPercentEscapedHref_IsStillAdmittedAtOnce() async throws {
    let chunk = 128 * 1024
    let escapedHref = "my%20track.mp3"
    let probe1 = ResourceProbe()
    probe!.length = UInt64(chunk * 200)
    probe!.readDelay = 0.05
    probe1.length = UInt64(chunk)
    probe1.readDelay = 0
    provider.addTrack(href: escapedHref, probe: probe1)

    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 20,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 2,
      maxTransferringTracks: 1,
      maxTransferYield: 10
    )

    let longReader = FakeLoadingRequest(
      url: Self.trackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 200, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: longReader))
    try await waitUntil(timeout: 5) { longReader.respondedBytes > 0 }

    // What the player records: the decoded path for the activity counters, and
    // the reading order's spelling for admission.
    let escapedURL = URL(string: "readium-lcp://track1/\(escapedHref)")!
    loader.noteTrack(
      key: "chapter-2",
      servesHref: LCPResourceLoaderDelegate.requestedHref(for: escapedURL),
      readingOrderHref: escapedHref
    )
    loader.markChapterLoadStart(trackKey: "chapter-2")

    let preferred = FakeLoadingRequest(
      url: escapedURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: preferred))

    try await waitUntil(timeout: 1) { preferred.respondedBytes > 0 }
    XCTAssertEqual(loader.peakTransferringTrackCount, 2,
                   "an escaped href must match the reading order's spelling, not the decoded path")
  }

  /// A track nobody marked is still subject to the bound.
  ///
  /// The exemption has to be narrow: if it admitted everything the bound would
  /// be gone, and read-ahead would pile up again.
  func testPreferredTrack_ATrackThatIsNotPreferred_IsStillHeld() async throws {
    let chunk = 128 * 1024
    let probe1 = ResourceProbe()
    probe!.length = UInt64(chunk * 200)
    probe!.readDelay = 0.05
    probe1.length = UInt64(chunk)
    probe1.readDelay = 0
    provider.addTrack(href: "track1.mp3", probe: probe1)

    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 20,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 2,
      maxTransferringTracks: 1,
      maxTransferYield: 10
    )

    let longReader = FakeLoadingRequest(
      url: Self.trackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 200, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: longReader))
    try await waitUntil(timeout: 5) { longReader.respondedBytes > 0 }

    // Marked, but for a different track than the one that asks.
    loader.noteTrack(key: "chapter-9", servesHref: "track9.mp3", readingOrderHref: "track9.mp3")
    loader.markChapterLoadStart(trackKey: "chapter-9")

    let held = FakeLoadingRequest(
      url: Self.otherTrackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )
    let bytesBefore = longReader.respondedBytes
    XCTAssertTrue(loader.shouldWait(for: held))

    // Wait on something that is false on entry: the slot holder delivering
    // more than it had when `held` was submitted. That proves reading time
    // passed, which a barrier already true on entry would not, and the
    // exempted case needs less than this to deliver its first byte.
    try await waitUntil(timeout: 5) { longReader.respondedBytes > bytesBefore }

    XCTAssertEqual(held.respondedBytes, 0,
                   "a track the patron is not waiting on must not skip the bound")
    XCTAssertEqual(loader.peakTransferringTrackCount, 1,
                   "the exemption must apply to the marked track only")
  }

  /// Being held back is bounded, so a track never waits forever for a slot.
  ///
  /// The slot is an optimisation, not a gate: past the deadline the transfer
  /// reads anyway. Without that, one long reader would stall every other track
  /// behind it.
  func testTransferBound_WhenASlotNeverFreesUp_TheHeldTransferReadsAnyway() async throws {
    let chunk = 128 * 1024
    let probe1 = ResourceProbe()
    probe!.length = UInt64(chunk * 200)
    probe!.readDelay = 0.05
    probe1.length = UInt64(chunk)
    probe1.readDelay = 0
    provider.addTrack(href: "track1.mp3", probe: probe1)

    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 20,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 1,
      maxTransferringTracks: 1,
      maxTransferYield: 0.3
    )

    let longReader = FakeLoadingRequest(
      url: Self.trackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 200, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: longReader))
    try await waitUntil(timeout: 5) { longReader.respondedBytes > 0 }

    let held = FakeLoadingRequest(
      url: Self.otherTrackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: held))

    let heldOutcome = try await held.waitUntilFinished(timeout: 10)
    XCTAssertEqual(heldOutcome, .success,
                   "the hold must expire rather than keep a request waiting indefinitely")
    XCTAssertEqual(held.respondedBytes, chunk)
  }

  /// A finished transfer gives its slot back.
  ///
  /// Without deregistration the bound fills with tracks that are no longer
  /// reading, and then holds back a track while nothing else is transferring,
  /// causing the stall it exists to prevent.
  func testTransferBound_AfterTransfersFinish_ALaterTrackIsNotHeldBack() async throws {
    let chunk = 128 * 1024
    let probe1 = ResourceProbe()
    let probe2 = ResourceProbe()
    for p in [probe!, probe1] {
      p.length = UInt64(chunk)
      p.readDelay = 0
    }
    probe2.length = UInt64(chunk * 2)
    probe2.readDelay = 0
    provider.addTrack(href: "track1.mp3", probe: probe1)
    provider.addTrack(href: "track2.mp3", probe: probe2)

    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 1,
      maxTransferringTracks: 1,
      // Long enough that a leaked slot shows up as a timeout rather than being
      // papered over by the deadline expiring.
      maxTransferYield: 30
    )

    for url in [Self.trackURL, Self.otherTrackURL] {
      let request = FakeLoadingRequest(
        url: url, needsContentInformation: false,
        range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
      )
      XCTAssertTrue(loader.shouldWait(for: request))
      let outcome = try await request.waitUntilFinished(timeout: 10)
      XCTAssertEqual(outcome, .success)
    }

    let later = FakeLoadingRequest(
      url: URL(string: "readium-lcp://track2/track2.mp3")!, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 2, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: later))

    let laterOutcome = try await later.waitUntilFinished(timeout: 10)
    XCTAssertEqual(laterOutcome, .success,
                   "slots from finished transfers must be released")
    XCTAssertEqual(later.respondedBytes, chunk * 2)
  }

  /// Serving no more tracks than the window holds delays nothing.
  ///
  /// The bound must not touch the steady state: the queued chapter and the
  /// preloaded following one are both legitimate and must both keep reading.
  func testTransferBound_WhenTheTracksServedFitTheWindow_BothKeepReading() async throws {
    let chunk = 128 * 1024
    let probe1 = ResourceProbe()
    for p in [probe!, probe1] {
      p.length = UInt64(chunk * 16)
      p.readDelay = 0.05
    }
    provider.addTrack(href: "track1.mp3", probe: probe1)

    let loader = LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: chunk,
      maxBufferedTracks: 2,
      maxTransferringTracks: 2
    )

    let current = FakeLoadingRequest(
      url: Self.trackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 16, toEnd: false)
    )
    let following = FakeLoadingRequest(
      url: Self.otherTrackURL, needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 16, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: current))
    try await waitUntil(timeout: 5) { current.respondedBytes > 0 }
    XCTAssertTrue(loader.shouldWait(for: following))
    try await waitUntil(timeout: 5) { following.respondedBytes > 0 }

    let currentAtStart = current.respondedBytes
    try await waitUntil(timeout: 5) { current.respondedBytes > currentAtStart }

    XCTAssertNil(current.outcome, "neither serve is finished early")
    XCTAssertGreaterThan(following.respondedBytes, 0, "the preloaded next chapter must keep reading")
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

  /// The same cancellation contract at the size the loader actually ships.
  /// The buffer makes a read one fill rather than one segment, so a cancel can
  /// no longer land between segments; what must still hold is that no further
  /// fill is started once AVFoundation has cancelled.
  func testDidCancel_AtTheShippedBufferSize_StartsNoFurtherFill() async throws {
    let fill = LCPResourceLoaderDelegate.defaultPerTrackBufferSize
    probe.length = UInt64(fill * 3)
    probe.readDelay = 0.05
    let loader = LCPResourceLoaderDelegate(provider: provider, stallTimeout: 5)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: fill * 3, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    try await waitUntil(timeout: 5) { self.probe.reads > 0 }
    loader.didCancel(request)
    let readsAtCancel = probe.reads

    try await Task.sleep(nanoseconds: 600_000_000)

    XCTAssertLessThanOrEqual(
      probe.reads,
      readsAtCancel + 1,
      "at most the fill in flight at cancel may complete; a cancelled request starts no new one"
    )
    XCTAssertLessThan(
      probe.reads,
      3,
      "the whole track must not be read after a cancel — three fills would cover it"
    )
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

  // MARK: - Where the length comes from

  /// A resolution for this archive reads a track's length in two small ranges.
  /// Readium's own probe reads the entry's CBC tail through the shared window,
  /// measured on device at 18.6 MB of origin traffic to deliver two bytes. So
  /// when the provider says an answer is coming, the loader waits for it and
  /// the probe is never run.
  func testContentInfo_whenTheProviderSuppliesTheLength_doesNotProbeTheArchive() async throws {
    probe.length = 9_999
    provider.suppliedLength = 4_073
    provider.lengthWait = 0.2
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(request.contentLength, 4_073, "the length the resolution supplied is served")
    XCTAssertEqual(probe.lengthLookups, 0, "the archive tail is never read for a length already coming")
    XCTAssertEqual(
      provider.waitsAsked.first,
      LCPResourceLoaderDelegate.lengthWaitTimeout,
      "the loader states how long it is prepared to wait"
    )
  }

  /// The case a chapter change actually hits: AVFoundation's first data request
  /// is two bytes, and a read of a CBC resource fetches the entry's tail before
  /// it decrypts anything. The length the provider supplied must reach the
  /// resource the bytes are read from, or that read pays the 18.6 MB anyway.
  func testDataRequest_whenTheProviderSuppliesTheLength_doesNotProbeTheArchive() async throws {
    probe.length = 9_999
    provider.suppliedLength = 4_073
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: 2, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(request.respondedBytes, 2)
    XCTAssertEqual(probe.lengthLookups, 0, "a supplied length spares the read its tail fetch")
  }

  /// With no resolution running there is nothing to wait for — a local package,
  /// or a book whose resolution has already finished without this track. The
  /// probe is the only remaining answer and the chapter must still play.
  func testContentInfo_whenNoLengthIsComing_fallsBackToTheArchiveProbe() async throws {
    probe.length = 4_096
    provider.suppliedLength = nil
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(request.contentLength, 4_096)
    XCTAssertEqual(probe.lengthLookups, 1, "the probe answers when nothing else will")
  }

  /// A length the probe had to learn must be remembered, or the next session
  /// pays the same megabytes for the same answer.
  func testContentInfo_whenTheProbeLearnedTheLength_isWrittenBackToTheProvider() async throws {
    probe.length = 4_096
    provider.suppliedLength = nil
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(provider.writes.map(\.href), [Self.href])
    XCTAssertEqual(provider.writes.map(\.length), [4_096])
  }

  /// A length the provider supplied is already stored there, so writing it
  /// back says nothing and would hide whether the probe ever ran.
  func testContentInfo_whenTheProviderSuppliedTheLength_isNotWrittenBack() async throws {
    probe.length = 9_999
    provider.suppliedLength = 4_073
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertEqual(request.contentLength, 4_073)
    XCTAssertTrue(provider.writes.isEmpty, "nothing new was learned, so nothing is written")
  }

  // MARK: - What a serve records

  /// The exported log has to say which track a slow serve was for and what
  /// AVFoundation asked of it. Without those two fields a chapter the patron
  /// is waiting for and one they have already left read the same.
  func testServe_RecordsTheTrackTheRangeAndWhatItDelivered() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk * 2)
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success)
    try await waitUntil(timeout: 5) { !loader.serveReports.value.isEmpty }

    let report = try XCTUnwrap(loader.serveReports.value.last)
    XCTAssertEqual(report.href, Self.href)
    XCTAssertEqual(report.range, LCPRequestedRange(offset: 0, length: chunk, toEnd: false))
    XCTAssertEqual(report.deliveredBytes, chunk)
    XCTAssertFalse(report.wasCancelled)
    XCTAssertTrue(
      report.description.contains(Self.href),
      "the line a patron exports must name the track: \(report.description)"
    )
  }

  /// A chapter the patron has left is recognisable by two fields together: it
  /// was cancelled, and it delivered less than it was asked for.
  func testServe_WhenCancelledMidTransfer_RecordsTheCancelAndWhatItHadDelivered() async throws {
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

    try await waitUntil(timeout: 5) { !loader.serveReports.value.isEmpty }
    let report = try XCTUnwrap(loader.serveReports.value.last)
    XCTAssertTrue(report.wasCancelled)
    XCTAssertGreaterThan(report.deliveredBytes, 0)
    XCTAssertLessThan(report.deliveredBytes, chunk * 8)
    XCTAssertTrue(
      report.description.contains("cancelled"),
      "a cancelled serve must say so: \(report.description)"
    )
  }

  /// Two chapters transferring at once must each report their own bytes. The
  /// loader-wide counter credited a serve with every byte that arrived while
  /// it ran, which is what made a superseded chapter read as busy.
  func testServe_WithASecondTrackTransferringAtTheSameTime_ReportsOnlyItsOwnBytes() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk)
    let otherProbe = ResourceProbe()
    otherProbe.length = UInt64(chunk * 8)
    otherProbe.readDelay = 0.05
    provider.addTrack(href: "track1.mp3", probe: otherProbe)
    let loader = makeLoader(stallTimeout: 5)
    let other = FakeLoadingRequest(
      url: Self.otherTrackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk * 8, toEnd: false)
    )
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: other))
    try await waitUntil(timeout: 5) { other.respondedBytes > 0 }
    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success)
    try await waitUntil(timeout: 5) { loader.serveReports.value.contains { $0.href == Self.href } }

    let report = try XCTUnwrap(loader.serveReports.value.first { $0.href == Self.href })
    XCTAssertEqual(
      report.deliveredBytes,
      chunk,
      "the other track's bytes belong to the other track's report"
    )
    loader.cancelAllRequests()
    otherProbe.releaseAll()
  }

  /// A content-information request asks for no bytes at all, so reporting zero
  /// delivered bytes would read as a transfer that produced nothing. What it
  /// costs is the length lookup, and the line says that instead.
  func testServe_ForContentInformationOnly_SaysSoRatherThanReportingAnEmptyTransfer() async throws {
    probe.length = 4096
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success)
    try await waitUntil(timeout: 5) { !loader.serveReports.value.isEmpty }

    let report = try XCTUnwrap(loader.serveReports.value.last)
    XCTAssertNil(report.range)
    XCTAssertEqual(report.deliveredBytes, 0)
    XCTAssertNotNil(report.lengthProbe, "the length lookup is what this request spends its time on")
    XCTAssertTrue(
      report.description.contains("content information"),
      "a request that asked for no bytes must not read as an empty transfer: \(report.description)"
    )
  }

  /// Which serves reach the log. The threshold is the boundary a patron
  /// notices, so it belongs to the report rather than to the call site, and a
  /// serve exactly at it counts as slow.
  func testServeReport_IsWorthALogLineFromTheThresholdUp() {
    let threshold = LCPResourceLoaderDelegate.slowChapterServeThreshold

    XCTAssertFalse(Self.report(elapsed: threshold - 0.1).isWorthALogLine)
    XCTAssertTrue(Self.report(elapsed: threshold).isWorthALogLine)
    XCTAssertTrue(Self.report(elapsed: threshold + 1).isWorthALogLine)
  }

  /// The retained reports are a diagnostic tail, not a history: a long
  /// listening session must not keep one per chapter serve for the life of the
  /// player.
  func testServeReports_KeepOnlyTheMostRecent() async throws {
    probe.length = 4096
    let loader = makeLoader(stallTimeout: 5)
    for _ in 0..<(LCPResourceLoaderDelegate.maxRetainedServeReports + 3) {
      let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)
      XCTAssertTrue(loader.shouldWait(for: request))
      let outcome = try await request.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success)
    }

    try await waitUntil(timeout: 5) {
      loader.serveReports.value.count >= LCPResourceLoaderDelegate.maxRetainedServeReports
    }
    XCTAssertEqual(
      loader.serveReports.value.count,
      LCPResourceLoaderDelegate.maxRetainedServeReports
    )
  }

  // MARK: - What the loader was asked for, per track

  /// The byte counter cannot tell a loader that is serving nothing from a
  /// loader nothing has asked, because both read zero. The player's load
  /// timeout decides whether to fail a chapter on that difference, so the
  /// loader counts what it was handed, per track.
  func testRequestCount_CountsEveryLoadingRequestPerTrack() async throws {
    probe.length = 4096
    let otherProbe = ResourceProbe()
    otherProbe.length = 4096
    provider.addTrack(href: "track1.mp3", probe: otherProbe)
    let loader = makeLoader(stallTimeout: 5)

    for _ in 0..<2 {
      XCTAssertTrue(loader.shouldWait(for: FakeLoadingRequest(
        url: Self.trackURL, needsContentInformation: true, range: nil
      )))
    }
    XCTAssertTrue(loader.shouldWait(for: FakeLoadingRequest(
      url: Self.otherTrackURL, needsContentInformation: true, range: nil
    )))

    XCTAssertEqual(loader.loadingRequests(forHref: Self.href).received, 2)
    XCTAssertEqual(loader.loadingRequests(forHref: "track1.mp3").received, 1)
    loader.cancelAllRequests()
    otherProbe.releaseAll()
  }

  /// A track nothing has asked for reads zero, which is the answer the player
  /// acts on: there were never going to be bytes for it.
  func testRequestCount_ForATrackNothingAskedFor_IsZero() {
    let loader = makeLoader(stallTimeout: 5)

    XCTAssertEqual(loader.loadingRequests(forHref: "track7.mp3").received, 0)
  }

  /// A URL this loader does not serve is not a request for any track, so it
  /// must not make one look busy.
  func testRequestCount_DoesNotCountAURLThisLoaderDoesNotServe() {
    let loader = makeLoader(stallTimeout: 5)
    let foreign = FakeLoadingRequest(
      url: URL(string: "https://example.com/track0.mp3")!,
      needsContentInformation: true,
      range: nil
    )

    XCTAssertFalse(loader.shouldWait(for: foreign))
    XCTAssertEqual(loader.loadingRequests(forHref: "track0.mp3").received, 0)
  }

  /// A fast repeated failure and a stalled transfer both serve zero bytes. The
  /// failure count is what tells them apart, so the loader keeps it per track.
  func testRequestCount_WhenAServeFails_CountsTheFailureAgainstTheTrack() async throws {
    let loader = makeLoader(stallTimeout: 5)
    let missing = FakeLoadingRequest(
      url: URL(string: "readium-lcp://track9/absent.mp3")!,
      needsContentInformation: true,
      range: nil
    )

    XCTAssertTrue(loader.shouldWait(for: missing))
    let outcome = try await missing.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .failure(domain: "LCPResourceLoader", code: 2))
    try await waitUntil(timeout: 5) {
      loader.loadingRequests(forHref: "absent.mp3").failed == 1
    }
    XCTAssertEqual(loader.loadingRequests(forHref: "absent.mp3").received, 1)
  }

  /// A serve that succeeds must not be counted as a failure, or the count that
  /// separates a failing track from a slow one says nothing.
  func testRequestCount_WhenAServeSucceeds_CountsNoFailure() async throws {
    probe.length = 4096
    let loader = makeLoader(stallTimeout: 5)
    let request = FakeLoadingRequest(url: Self.trackURL, needsContentInformation: true, range: nil)

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)
    XCTAssertEqual(outcome, .success)
    try await waitUntil(timeout: 5) { !loader.serveReports.value.isEmpty }

    XCTAssertEqual(loader.loadingRequests(forHref: Self.href).failed, 0)
  }

  /// The player asks by track, because that is what it has; the loader counts
  /// by URL, because that is what AVFoundation hands it. The pairing is
  /// recorded when the item is built so the two cannot drift apart.
  func testRequestCount_IsReadableByTheTrackTheItemWasBuiltFor() {
    probe.length = 4096
    let loader = makeLoader(stallTimeout: 5)
    loader.noteTrack(key: "chapter-46", servesHref: Self.href)

    XCTAssertTrue(loader.shouldWait(for: FakeLoadingRequest(
      url: Self.trackURL, needsContentInformation: true, range: nil
    )))

    XCTAssertEqual(loader.loadingRequests(forTrackKey: "chapter-46")?.received, 1)
    loader.cancelAllRequests()
  }

  /// A track no item has been built for reads nil rather than zero: the two
  /// lead to opposite verdicts in the player's load timeout.
  func testRequestCount_ForATrackWithNoItemBuiltThroughThisLoader_IsUnknown() {
    let loader = makeLoader(stallTimeout: 5)

    XCTAssertNil(loader.loadingRequests(forTrackKey: "chapter-46"))
  }

  // MARK: - A serve that fails leaves a line whatever it cost

  /// The threshold was the only thing deciding what reached the log, so a serve
  /// that failed in a few milliseconds left no trace — and a failed item is
  /// then forced onto the streaming path and rebuilt, which can repeat without
  /// a single line in the exported log.
  func testServeReport_AFailedServeIsWorthALogLineHoweverFastItWas() {
    XCTAssertTrue(Self.report(elapsed: 0.01, failure: "Track not found in reading order").isWorthALogLine)
  }

  /// A cancelled serve too: a chapter the patron left is how a superseded read
  /// ends, and it is the context for the serve they are waiting on.
  func testServeReport_ACancelledServeIsWorthALogLineHoweverFastItWas() {
    XCTAssertTrue(Self.report(elapsed: 0.01, wasCancelled: true).isWorthALogLine)
  }

  /// And a fast serve that neither failed nor was cancelled stays out of the
  /// log, or a line per segment read buries the ones that matter.
  func testServeReport_AFastSuccessfulServeStaysOutOfTheLog() {
    XCTAssertFalse(Self.report(elapsed: 0.01).isWorthALogLine)
  }

  /// The line has to name the failure, not only its existence: the cause is
  /// what distinguishes a missing track from a transport error.
  func testServeReport_NamesTheFailureInTheLine() {
    let line = Self.report(elapsed: 0.01, failure: "Track not found in reading order").description

    XCTAssertTrue(line.contains("failed"), line)
    XCTAssertTrue(line.contains("Track not found in reading order"), line)
  }

  /// Driven through the shipped path, so the recording is asserted over the
  /// real failure exit rather than over a hand-built report.
  func testServe_WhenTheTrackIsNotInTheReadingOrder_RecordsTheFailure() async throws {
    let loader = makeLoader(stallTimeout: 5)
    let missing = FakeLoadingRequest(
      url: URL(string: "readium-lcp://track9/absent.mp3")!,
      needsContentInformation: true,
      range: nil
    )

    XCTAssertTrue(loader.shouldWait(for: missing))
    _ = try await missing.waitUntilFinished(timeout: 5)
    try await waitUntil(timeout: 5) { !loader.serveReports.value.isEmpty }

    let report = try XCTUnwrap(loader.serveReports.value.last)
    XCTAssertNotNil(report.failure, "a serve that failed must say so in its report")
    XCTAssertTrue(report.isWorthALogLine, "and reach the log however fast it was")
  }

  // MARK: - Timing a chapter start

  /// What a patron waits for is the FIRST byte, and nothing measured it: the
  /// serve reports state a request's total only once it is over. The mark
  /// records when the first byte of a marked load reached AVFoundation.
  func testChapterLoadMark_recordsWhenTheFirstByteWasHandedOver() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk)
    let loader = makeLoader(stallTimeout: 5)
    loader.markChapterLoadStart()
    XCTAssertNil(loader.chapterLoadMark?.firstByteAt, "nothing has been served yet")
    let request = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )

    XCTAssertTrue(loader.shouldWait(for: request))
    let outcome = try await request.waitUntilFinished(timeout: 5)

    XCTAssertEqual(outcome, .success)
    XCTAssertNotNil(loader.chapterLoadMark?.firstByteAt, "the first byte must be timed")
    XCTAssertEqual(loader.chapterLoadMark?.bytesAtStart, 0)
  }

  /// A new chapter supersedes the old mark, so a start is never reported
  /// against a load the patron has already left.
  func testChapterLoadMark_whenANewLoadBegins_timesTheNewOne() async throws {
    let chunk = 128 * 1024
    probe.length = UInt64(chunk * 2)
    let loader = makeLoader(stallTimeout: 5)
    loader.markChapterLoadStart()
    let first = FakeLoadingRequest(
      url: Self.trackURL,
      needsContentInformation: false,
      range: LCPRequestedRange(offset: 0, length: chunk, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: first))
    _ = try await first.waitUntilFinished(timeout: 5)
    let servedByFirstLoad = loader.bytesServed
    XCTAssertGreaterThan(servedByFirstLoad, 0)

    loader.markChapterLoadStart()

    XCTAssertNil(loader.chapterLoadMark?.firstByteAt, "the new load has served nothing yet")
    XCTAssertEqual(
      loader.chapterLoadMark?.bytesAtStart,
      servedByFirstLoad,
      "bytes the previous chapter served are not credited to this one"
    )
  }

  // MARK: - Helpers

  private static func report(
    elapsed: TimeInterval,
    wasCancelled: Bool = false,
    failure: String? = nil
  ) -> LCPResourceLoaderDelegate.ServeReport {
    LCPResourceLoaderDelegate.ServeReport(
      href: href,
      range: nil,
      elapsed: elapsed,
      lengthProbe: nil,
      originRequests: 0,
      originBytes: 0,
      deliveredBytes: 0,
      wasCancelled: wasCancelled,
      failure: failure
    )
  }

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
/// One instance's memoized length answer.
private final class LengthMemo: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ReadResult<UInt64?>?
  var value: ReadResult<UInt64?>? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

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

private final class FakeResource: KnownLengthAcceptingResource {
  let probe: ResourceProbe
  private let memo = LengthMemo()
  private let knownLength: UInt64?
  init(probe: ResourceProbe, knownLength: UInt64? = nil) {
    self.probe = probe
    self.knownLength = knownLength
  }

  let sourceURL: AbsoluteURL? = nil
  func properties() async -> ReadResult<ResourceProperties> { .success(ResourceProperties()) }

  func withKnownLength(_ length: UInt64) -> Resource {
    FakeResource(probe: probe, knownLength: length)
  }

  /// Memoized per instance, as Readium's CBC resource is: it holds its tail
  /// fetch in a `lazy var`, so asking one instance twice costs one fetch while
  /// a fresh instance costs another. The probe counts fetches, so without this
  /// the fakes would report network the real stack never performs.
  func estimatedLength() async -> ReadResult<UInt64?> {
    if let knownLength { return .success(knownLength) }
    if let held = memo.value { return held }
    let result = await probe.estimatedLength()
    memo.value = result
    return result
  }
  /// Readium's CBC resource awaits its plaintext length before decrypting any
  /// range, so a read costs the tail fetch unless the length was supplied.
  func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
    if case let .failure(error) = await estimatedLength() {
      return .failure(error)
    }
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
  private var _suppliedLength: UInt64?
  private var _lengthWait: TimeInterval = 0
  private var _waitsAsked: [TimeInterval] = []
  private var _writes: [(href: String, length: UInt64)] = []
  private var _stored: [String: UInt64] = [:]

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

  /// What a resolution running for this archive will supply, after `lengthWait`.
  /// nil means nothing is coming, which is what sends the loader to the probe.
  var suppliedLength: UInt64? {
    get { lock.withLock { _suppliedLength } }
    set { lock.withLock { _suppliedLength = newValue } }
  }

  var lengthWait: TimeInterval {
    get { lock.withLock { _lengthWait } }
    set { lock.withLock { _lengthWait = newValue } }
  }

  /// The timeouts the loader asked to wait, in order.
  var waitsAsked: [TimeInterval] { lock.withLock { _waitsAsked } }

  /// What the loader asked to be remembered, in order. Recorded but not
  /// served back: a write that changed later answers would change what the
  /// other tests here measure.
  var writes: [(href: String, length: UInt64)] { lock.withLock { _writes } }

  func cachePlaintextLength(_ length: UInt64, forHref href: String) {
    lock.withLock { _writes.append((href: href, length: length)) }
  }

  /// Empty unless a test stores one, which is the state the loader meets on a
  /// first open.
  func cachedPlaintextLength(forHref href: String) -> UInt64? {
    lock.withLock { _stored[href] }
  }

  func store(length: UInt64, forHref href: String) {
    lock.withLock { _stored[href] = length }
  }

  func plaintextLength(forHref href: String, waitingUpTo timeout: TimeInterval) async -> UInt64? {
    let (supplied, wait): (UInt64?, TimeInterval) = lock.withLock {
      _waitsAsked.append(timeout)
      return (_suppliedLength, _lengthWait)
    }
    guard let supplied else { return nil }
    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    return supplied
  }

  // The protocol requires these without a default so no conformer can
  // silently skip them; this fake is not exercising the yield behaviour.
  func streamingLoadDidBegin() {}
  func streamingLoadDidEnd() {}

  private static func makePublication(hrefs: [String], container: Container) -> Publication {
    Publication(
      manifest: Manifest(
        metadata: Metadata(title: "PP-5240"),
        readingOrder: hrefs.map { Link(href: $0, mediaType: .mp3) }
      ),
      container: container
    )
  }

  /// A maximal hold must not log itself as a slow chapter serve.
  ///
  /// The slow-serve predicate is `elapsed >= slowChapterServeThreshold`, so an
  /// equal yield would put a self-inflicted line into the diagnostic the
  /// regression pass reads to find real stalls. Both constants were unpinned
  /// until this test, and they were briefly equal.
  func testTheMaximalHold_doesNotRegisterAsASlowChapterServe() {
    XCTAssertLessThan(
      LCPResourceLoaderDelegate.defaultMaxTransferYield,
      LCPResourceLoaderDelegate.slowChapterServeThreshold,
      "a hold of the full yield must stay under the slow-serve threshold, which compares with >="
    )
  }
}
