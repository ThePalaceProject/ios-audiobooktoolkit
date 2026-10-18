//
//  PartialArchiveCacheWritePathTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-5367 — caching a window must not delay the chapter that window is for.
//

import Foundation
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

/// The real store commits a window with `pwrite`, then `F_FULLFSYNC` on the
/// archive, then a journal append with a second `F_FULLFSYNC`. On a device, with
/// a sparse multi-gigabyte archive, that is the slowest step on the path — and
/// the patron is waiting on the chapter those bytes are for, not on the cache.
final class PartialArchiveCacheWritePathTests: XCTestCase {

  private let archiveURL = HTTPURL(string: "https://example.invalid/book.lcpa")!
  private let archiveLength: UInt64 = 1_261_721_882

  /// Longer than any plausible scheduling delay, so the assertion is about the
  /// response waiting on the write rather than about machine speed.
  private let writeDelay: TimeInterval = 1.0

  func testARangeFetched_isServedWithoutWaitingForTheStoreWrite() async {
    let range: Range<UInt64> = 0 ..< 6_291_456
    let store = SlowWriteStore(totalSize: archiveLength, delay: writeDelay)
    let upstream = ScriptedAnswerClient(
      status: 206,
      headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(archiveLength)"],
      body: Data(repeating: 0x5A, count: range.count)
    )
    let client = PartialArchiveCachingHTTPClient(
      upstream: upstream,
      storeFactory: { _, _ in store }
    )

    var request = HTTPRequest(url: archiveURL)
    request.setRange(range)

    let started = Date()
    let result = await client.stream(request: request) { _, _ in .success(()) }
    let elapsed = Date().timeIntervalSince(started)

    guard case .success = result else {
      return XCTFail("premise: the range must be served, got \(result)")
    }
    XCTAssertLessThan(
      elapsed, writeDelay / 2,
      "the response must not wait for the store's flush — the patron is waiting on this chapter"
    )

    // And the write must still happen: a cache that drops the window would make
    // the next read refetch it, which is the cost this cache exists to remove.
    let wrote = await store.waitForWrite(timeout: writeDelay * 4)
    XCTAssertTrue(wrote, "the window must still reach the store, just not on the read path")
    XCTAssertEqual(store.writtenRanges, [range])
  }
}

// MARK: - Doubles

/// A store whose commit is slow, standing in for the device's two flushes.
private final class SlowWriteStore: ArchiveRangeStore, @unchecked Sendable {
  let totalSize: UInt64
  private let delay: TimeInterval
  private let lock = NSLock()
  private var _written: [Range<UInt64>] = []

  init(totalSize: UInt64, delay: TimeInterval) {
    self.totalSize = totalSize
    self.delay = delay
  }

  var writtenRanges: [Range<UInt64>] { lock.withLock { _written } }

  func missingRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
    let held = writtenRanges
    return held.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound })
      ? []
      : [range]
  }

  @discardableResult
  func write(_ bytes: Data, at offset: UInt64) throws -> Range<UInt64> {
    Thread.sleep(forTimeInterval: delay)
    let committed = offset ..< offset + UInt64(bytes.count)
    lock.withLock { _written.append(committed) }
    return committed
  }

  func read(_ range: Range<UInt64>) throws -> Data {
    Data(repeating: 0x5A, count: range.count)
  }

  func waitForWrite(timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !writtenRanges.isEmpty { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
  }
}

/// Answers one scripted response, in two chunks as the real client delivers.
private final class ScriptedAnswerClient: HTTPClient, @unchecked Sendable {
  private let status: Int
  private let headers: [String: String]
  private let body: Data

  init(status: Int, headers: [String: String], body: Data) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    let split = body.count / 2
    for chunk in [Data(body.prefix(split)), Data(body.dropFirst(split))] where !chunk.isEmpty {
      if case let .failure(error) = consume(chunk, nil) { return .failure(error) }
    }
    return .success(HTTPResponse(
      request: req,
      url: req.url,
      status: HTTPStatus(rawValue: status) ?? .ok,
      headers: headers,
      mediaType: nil,
      body: nil
    ))
  }
}
