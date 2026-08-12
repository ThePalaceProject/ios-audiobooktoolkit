//
//  DownloadConcurrencyContractTests.swift
//  PalaceAudiobookToolkitTests
//
//  Concurrency contracts for the audiobook download path (PP-4724 Wave 2).
//
//  These exist because the rest of the suite is entirely sequential, and every
//  defect this wave fixed was a race. `ChunkStallRetryTests` is the clearest
//  illustration: it covers `attemptNetworkRetryAfterTransientError` thoroughly
//  — first call `true`, second `false`, re-arm — and passes *identically*
//  against the pre-fix code, because it never calls the method concurrently.
//  A green sequential suite is not evidence that a concurrency guard bites.
//
//  THREE tests here are mutation-verified: the defect each claims to cover was
//  reintroduced and the test confirmed to fail. Recorded so a future reader can
//  re-derive them rather than take it on trust:
//
//    testNetworkRetryBudget_UnderConcurrentClaims  -> get-then-set
//        -> 6 grants instead of 1 (needs 128 concurrent callers; at 32 it
//           passed against racy code across 200 trials)
//    testWatchdogStart_UnderConcurrentCalls        -> get-then-set
//        -> 2 transitions, caught at trial 27 (a single trial missed it)
//    testDownloadProgress_PublishesOnChange...     -> publish-on-every-set
//        -> [0.25, 0.25, 0.75] instead of [0.25, 0.75]
//
//  The remaining tests assert behavioural contracts (budget re-arm, watchdog
//  restartability, stop() idempotence). They are NOT race-mutation-verified and
//  are not claimed to be — they would catch a broken re-arm or a latched run
//  flag, not a missing lock.
//
//  Deliberately absent: a test for the lazy initialization of
//  `downloadProgress`. One was written and removed, because it could not be
//  made to fail. The getter returns early on a cached value, so the window in
//  which two racers can both resolve is a few instructions wide; even staging a
//  `.missing` -> `.saved` flip mid-race could not reliably widen it. A test
//  that cannot fail is worse than no test, since it advertises coverage that
//  does not exist. The guard itself is exercised indirectly by the concurrent
//  publish test and reviewed by inspection.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest

@testable import PalaceAudiobookToolkit

final class DownloadConcurrencyContractTests: XCTestCase {
  // MARK: - Fixtures

  /// - Note: the download URL points at the discard port on loopback rather
  ///   than a real host. `attemptNetworkRetryAfterTransientError` schedules a
  ///   `fetch()` 5 seconds after a successful claim; that closure captures
  ///   `self` weakly and every task here is trial-scoped, so it should never
  ///   run — but if the lifetime assumption ever breaks, an unroutable address
  ///   means the suite still cannot emit real network traffic.
  private func makeOpenAccessTask(token: String? = "test-token") -> OpenAccessDownloadTask {
    OpenAccessDownloadTask(
      key: "test-track-key",
      bookID: "test-book",
      downloadURL: URL(string: "http://127.0.0.1:9/track.mp3")!,
      urlString: "http://127.0.0.1:9/track.mp3",
      urlMediaType: .audioMPEG,
      alternateLinks: nil,
      feedbooksProfile: nil,
      token: token
    )
  }

  // MARK: - Retry budget is claimed exactly once (auth / money path)

  /// A transient failure can be delivered for several chapters at once on the
  /// shared URLSession delegate queue. The budget is "one retry per task", so
  /// exactly one concurrent caller may claim it.
  ///
  /// Pre-fix this was `guard !hasAttempted` then `hasAttempted = true` — two
  /// separate lock acquisitions — so multiple callers could each observe "not
  /// yet attempted" and all return `true`, producing duplicate retries against
  /// the content server.
  ///
  /// Repeated across trials for the same reason as the watchdog test: the
  /// check-then-claim window is only a few instructions wide, so a single trial
  /// can miss it. Verified against a deliberately reintroduced get-then-set —
  /// one trial caught it on one run and missed it on another, trials caught it
  /// reliably.
  func testNetworkRetryBudget_UnderConcurrentClaims_IsGrantedExactlyOnce() {
    for trial in 1...200 {
      let task = makeOpenAccessTask()
      let grants = LockIsolated(0)

      DispatchQueue.concurrentPerform(iterations: 128) { _ in
        if task.attemptNetworkRetryAfterTransientError() {
          grants.withValue { $0 += 1 }
        }
      }

      XCTAssertEqual(
        grants.value, 1,
        "trial \(trial): the once-per-task retry budget was claimed \(grants.value) times "
          + "concurrently; each extra claim is a duplicate download retry against the content server."
      )
      XCTAssertTrue(task.hasUsedNetworkRetry)
      if grants.value != 1 {
        return // one demonstration is enough
      }
    }
  }

  /// The budget must still be re-armable after a successful download, and the
  /// re-arm must not let a concurrent burst claim it more than once again.
  func testNetworkRetryBudget_AfterReArm_IsGrantedExactlyOnceAgain() {
    let task = makeOpenAccessTask()
    XCTAssertTrue(task.attemptNetworkRetryAfterTransientError())

    task.resetNetworkRetryBudget()
    let grants = LockIsolated(0)

    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      if task.attemptNetworkRetryAfterTransientError() {
        grants.withValue { $0 += 1 }
      }
    }

    XCTAssertEqual(grants.value, 1)
  }

  // MARK: - Publish semantics must not drift

  /// `OpenAccessDownloadTask` publishes only when the value actually changes.
  /// A drift to publish-on-every-set would spam the progress bar; a drift to
  /// never-publish would freeze it. Both are invisible without an assertion.
  func testDownloadProgress_PublishesOnChangeAndNotOnRepeat() {
    let task = makeOpenAccessTask()
    var received: [Float] = []
    var cancellables = Set<AnyCancellable>()

    // Resolve the lazy initial value first so its resolution does not count
    // as one of the transitions under test.
    _ = task.downloadProgress

    // Keyed on the FINAL distinct value rather than on a fulfillment count:
    // an `expectedFulfillmentCount` would raise an API-violation exception if
    // the code under test over-published, killing the test host instead of
    // failing an assertion — which is exactly what a publish-on-every-set
    // regression does.
    let sawFinalValue = expectation(description: "final progress value published")
    task.statePublisher
      .sink { state in
        if case let .progress(value) = state {
          received.append(value)
          if value == 0.75 {
            sawFinalValue.fulfill()
          }
        }
      }
      .store(in: &cancellables)

    task.downloadProgress = 0.25
    task.downloadProgress = 0.25 // repeat — must NOT publish
    task.downloadProgress = 0.75

    wait(for: [sawFinalValue], timeout: 2.0)

    XCTAssertEqual(
      received, [0.25, 0.75],
      "Publish-on-change semantics drifted; got \(received). A repeated value must not republish."
    )
  }

  // MARK: - Watchdog lifecycle

  /// Exactly one of N concurrent `start()` calls may transition the watchdog to
  /// running. Pre-fix the run flag was tested and set in two separate lock
  /// acquisitions, so several callers could each install a monitoring task; all
  /// but the last handle was dropped on the floor, leaving a timer `stop()`
  /// could not cancel and which kept firing stall checks — and therefore
  /// download retries — for the rest of the process's life.
  ///
  /// Repeated across many trials on purpose. The window between a separate
  /// `read` and `write` of the run flag is only a few instructions wide, so a
  /// single 64-thread trial frequently misses it — verified: against a
  /// deliberately reintroduced get-then-set, one trial passed. Trials raise the
  /// probability of observing the race to effectively certain while staying
  /// fast, since `start()` with a 60s interval never actually ticks.
  func testWatchdogStart_UnderConcurrentCalls_TransitionsExactlyOnce() {
    for trial in 1...200 {
      let watchdog = DownloadWatchdog(
        configuration: .init(stallTimeout: 60, maxRetries: 1, retryDelay: 60, checkInterval: 60)
      )
      let transitions = LockIsolated(0)

      DispatchQueue.concurrentPerform(iterations: 32) { _ in
        if watchdog.start() {
          transitions.withValue { $0 += 1 }
        }
      }
      watchdog.stop()

      XCTAssertEqual(
        transitions.value, 1,
        "trial \(trial): \(transitions.value) concurrent start() calls each installed a monitoring "
          + "task; all but one are orphaned and cannot be cancelled by stop()."
      )
      if transitions.value != 1 {
        return // one demonstration is enough; do not emit 200 identical failures
      }
    }
  }

  /// After `stop()`, the watchdog must be startable again — i.e. `stop()`
  /// genuinely released the run flag rather than leaving it latched.
  func testWatchdogStart_AfterStop_TransitionsAgain() {
    let watchdog = DownloadWatchdog(
      configuration: .init(stallTimeout: 60, maxRetries: 1, retryDelay: 60, checkInterval: 60)
    )
    defer { watchdog.stop() }

    XCTAssertTrue(watchdog.start(), "First start should transition")
    XCTAssertFalse(watchdog.start(), "Second start while running must be a no-op")

    watchdog.stop()

    XCTAssertTrue(watchdog.start(), "After stop, start must transition again")
  }

  /// `stop()` is documented as idempotent and safe from any thread, including
  /// racing itself (an explicit stop against `deinit`). Two concurrent stops
  /// must not both come away owning the same task handle.
  func testWatchdogStop_UnderConcurrentCalls_IsIdempotent() {
    let watchdog = DownloadWatchdog(
      configuration: .init(stallTimeout: 60, maxRetries: 1, retryDelay: 60, checkInterval: 60)
    )
    watchdog.start()

    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      watchdog.stop()
    }

    XCTAssertTrue(watchdog.start(), "After concurrent stops the watchdog must be cleanly restartable")
    watchdog.stop()
  }
}
