//
//  FindawayDownloadEngineGateTests.swift
//  PalaceAudiobookToolkitTests
//
//  Verifies the gate that serializes Findaway download-engine access.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class FindawayDownloadEngineGateTests: XCTestCase {
  /// The whole point of the gate: concurrent callers must never run their work
  /// closures at the same time. If the underlying queue were `.concurrent` (or
  /// the call sites bypassed the gate), this would observe overlap > 1 and the
  /// Findaway `FAEChapterStatus` semaphore would crash on device.
  func testPerform_underHeavyConcurrency_neverRunsTwoClosuresAtOnce() {
    let gate = FindawayDownloadEngineGate()

    // Plain (non-atomic) counters: if the gate fails to serialize, these are
    // mutated concurrently and `maxObservedConcurrency` races above 1 — exactly
    // the unsafe condition we are guarding against.
    var activeCount = 0
    var maxObservedConcurrency = 0
    var completed = 0

    let iterations = 200
    let group = DispatchGroup()

    for _ in 0..<iterations {
      group.enter()
      DispatchQueue.global().async {
        gate.perform {
          activeCount += 1
          maxObservedConcurrency = max(maxObservedConcurrency, activeCount)
          // Hold the critical section briefly so any concurrency would overlap.
          let deadline = Date().addingTimeInterval(0.0005)
          while Date() < deadline {}
          activeCount -= 1
          completed += 1
        }
        group.leave()
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 20), .success, "Gate work did not drain")
    XCTAssertEqual(completed, iterations, "Every queued closure must run exactly once")
    XCTAssertEqual(maxObservedConcurrency, 1, "Gate must serialize: no two closures may run concurrently")
    XCTAssertEqual(activeCount, 0, "Critical section must balance enter/exit")
  }

  /// `perform` is the value-returning seam the call sites depend on
  /// (`status(...)`, `percentage(...)`, `currentDownloadRequests()`), so a
  /// dropped/!ignored return would silently break download status.
  func testPerform_returnsClosureResult() {
    let gate = FindawayDownloadEngineGate()
    let result = gate.perform { 21 * 2 }
    XCTAssertEqual(result, 42)
  }

  func testPerform_propagatesOptionalResult() {
    let gate = FindawayDownloadEngineGate()
    let value: String? = gate.perform { Optional("downloaded") }
    XCTAssertEqual(value, "downloaded")
  }

  /// Nested `perform` from a DIFFERENT thread must still serialize rather than
  /// deadlock — proves callers may chain gated reads safely.
  func testPerform_serializesSequentialCallsAcrossThreads() {
    let gate = FindawayDownloadEngineGate()
    var order: [Int] = []
    let group = DispatchGroup()

    for i in 0..<50 {
      group.enter()
      DispatchQueue.global().async {
        gate.perform { order.append(i) }
        group.leave()
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(order.count, 50, "All gated writes recorded without lost updates")
  }
}
