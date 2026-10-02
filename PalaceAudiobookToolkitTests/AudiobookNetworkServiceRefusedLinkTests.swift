//
//  AudiobookNetworkServiceRefusedLinkTests.swift
//  PalaceAudiobookToolkitTests
//
//  A track whose server refuses the link (410 Gone, 403 Forbidden) must not be
//  handed back to the slot filler. OverDrive track links are signed and expire;
//  restarting the same expired link produced an unbounded fetch/fail loop for as
//  long as the player stayed open (PP-4967).
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookNetworkServiceRefusedLinkTests: XCTestCase {
  private typealias TrackMock = AudiobookNetworkServiceTest.TrackMock
  private typealias DownloadTaskMock = AudiobookNetworkServiceTest.DownloadTaskMock

  /// A track whose every fetch fails with `error`, counting the fetches.
  private func failingTrack(key: String, error: Error?) -> (TrackMock, () -> Int) {
    let track = TrackMock(progress: 0, key: key)
    let fetches = LockIsolated(0)
    track.downloadTask = DownloadTaskMock(progress: 0, key: key) { task in
      fetches.withValue { $0 += 1 }
      task.statePublisher.send(.error(error))
    }
    return (track, { fetches.value })
  }

  private func httpError(_ status: Int) -> NSError {
    NSError(
      domain: OpenAccessPlayerErrorDomain,
      code: OpenAccessPlayerError.unknown.rawValue,
      userInfo: ["httpStatusCode": status]
    )
  }

  /// Lets the service run several complete fail → release → refill cycles. Each
  /// drain waits for the service's queue and two main-queue hops, which covers
  /// one full cycle of the retry loop, so a loop that exists has advanced by the
  /// end.
  private func drain(_ service: DefaultAudiobookNetworkService, cycles: Int) async {
    for _ in 0..<cycles {
      let drained = expectation(description: "drained")
      service.whenPendingWorkDrains { drained.fulfill() }
      await fulfillment(of: [drained], timeout: 30)
    }
  }

  private func fetchCount(afterFailingWith error: Error?) async -> Int {
    let (track, fetches) = failingTrack(key: "t0", error: error)
    let service = DefaultAudiobookNetworkService(tracks: [track])
    service.fetch()
    await drain(service, cycles: 6)
    return fetches()
  }

  func testFetch_whenServerReturns410Gone_fetchesTheTrackOnce() async {
    let count = await fetchCount(afterFailingWith: httpError(410))
    XCTAssertEqual(count, 1, "an expired link cannot succeed on a retry; it must not be fetched again")
  }

  func testFetch_whenServerReturns403Forbidden_fetchesTheTrackOnce() async {
    let count = await fetchCount(afterFailingWith: httpError(403))
    XCTAssertEqual(count, 1, "a refused link cannot succeed on a retry; it must not be fetched again")
  }

  /// The refusal check reads the status, not merely the presence of an error:
  /// a server error is still handed back to the slot filler.
  func testFetch_whenServerReturns503_isStillRetried() async {
    let count = await fetchCount(afterFailingWith: httpError(503))
    XCTAssertGreaterThan(count, 1, "a 503 is not a refusal of the link and stays eligible for a retry")
  }

  func testFetch_whenErrorCarriesNoStatus_isStillRetried() async {
    let count = await fetchCount(afterFailingWith: nil)
    XCTAssertGreaterThan(count, 1, "a failure with no HTTP status is not a refusal of the link")
  }

  /// The status may arrive one level down, on the underlying error.
  func testFetch_whenRefusalIsOnTheUnderlyingError_fetchesTheTrackOnce() async {
    let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: httpError(410)])
    let count = await fetchCount(afterFailingWith: wrapped)
    XCTAssertEqual(count, 1)
  }

  /// One refused track must not stop the others: the slot it held moves on.
  func testFetch_afterARefusedTrack_theNextTrackIsStillFetched() async {
    let (refused, refusedFetches) = failingTrack(key: "t0", error: httpError(410))
    let next = TrackMock(progress: 0, key: "t1")
    let nextFetches = LockIsolated(0)
    next.downloadTask = DownloadTaskMock(progress: 0, key: "t1") { task in
      nextFetches.withValue { $0 += 1 }
      task.downloadProgress = 1
      task.statePublisher.send(.completed)
    }
    let service = DefaultAudiobookNetworkService(tracks: [refused, next])
    service.fetch()
    await drain(service, cycles: 6)

    XCTAssertEqual(refusedFetches(), 1)
    XCTAssertEqual(nextFetches.value, 1, "the other track downloads normally")
  }
}
