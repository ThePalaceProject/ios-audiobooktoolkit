//
//  ChunkStallRetryTests.swift
//  PalaceAudiobookToolkitTests
//
//  Tests for HelpSpot 17725: audiobook chunk-download retry on transient
//  network errors (server returns no HTTP response, idle stall mid-transfer,
//  dropped TCP). Mirrors the BearerTokenRefreshTests guard-semantics pattern.
//
//  Why this matters:
//  Patron 17725 reported "audiobook... reached about the halfway point
//  before it seemed to stall... error 914" (914 = invalidOrNoHTTPResponse
//  in ios-core's TPPErrorCode). Pre-fix, OpenAccessDownloadTask published a
//  terminal `connectionLost` error to its publisher on the first transient
//  blip, killing the rest of the audiobook download. The fix adds a single
//  bounded inline retry (5s delay) before publishing the terminal error,
//  re-armed on successful completion.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

final class ChunkStallRetryTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeTask(token: String? = "test-token") -> OpenAccessDownloadTask {
        OpenAccessDownloadTask(
            key: "test-track-key",
            downloadURL: URL(string: "https://example.com/track.mp3")!,
            urlString: "https://example.com/track.mp3",
            urlMediaType: .audioMPEG,
            alternateLinks: nil,
            feedbooksProfile: nil,
            token: token
        )
    }

    // MARK: - attemptNetworkRetryAfterTransientError — guard semantics

    /// Default state: the retry budget is fully available (one retry per
    /// task instance). First call should return true.
    func testAttemptRetry_freshTask_returnsTrue() {
        let task = makeTask()

        XCTAssertFalse(task.hasUsedNetworkRetry, "Pre-condition: a fresh task has not used its retry budget")

        let result = task.attemptNetworkRetryAfterTransientError()

        XCTAssertTrue(result, "First call on a fresh task must schedule a retry")
        XCTAssertTrue(task.hasUsedNetworkRetry, "Calling attempt must consume the once-per-task budget")
    }

    /// Second call on the same task instance must return false — protects
    /// against retry storms when the underlying problem is persistent.
    func testAttemptRetry_secondAttemptOnSameTask_returnsFalse() {
        let task = makeTask()

        let first = task.attemptNetworkRetryAfterTransientError()
        XCTAssertTrue(first)

        let second = task.attemptNetworkRetryAfterTransientError()

        XCTAssertFalse(second, "Second retry attempt on the same task instance must return false (one inline retry per task)")
    }

    /// Successful download re-arms the budget. The URLSession delegate
    /// calls `resetNetworkRetryBudget()` on `didFinishDownloadingTo` after
    /// a successful move; this test exercises that contract directly.
    func testAttemptRetry_reArmedAfterSuccessfulCompletion() {
        let task = makeTask()

        XCTAssertTrue(task.attemptNetworkRetryAfterTransientError(),
                      "First retry should fire")
        XCTAssertFalse(task.attemptNetworkRetryAfterTransientError(),
                       "Second retry on same task should be blocked")

        task.resetNetworkRetryBudget()

        XCTAssertFalse(task.hasUsedNetworkRetry,
                       "resetNetworkRetryBudget must clear the once-per-task flag")
        XCTAssertTrue(task.attemptNetworkRetryAfterTransientError(),
                      "After reset, retry budget should be available again")
    }

    /// Each task instance has its own retry budget — exhausting one must
    /// not affect another. Locks against any accidental shared state
    /// (e.g. a static counter slipping in during a refactor).
    func testAttemptRetry_budgetIsPerTaskInstance() {
        let taskA = makeTask()
        let taskB = makeTask()

        XCTAssertTrue(taskA.attemptNetworkRetryAfterTransientError(),
                      "taskA first retry should fire")
        XCTAssertFalse(taskA.attemptNetworkRetryAfterTransientError(),
                       "taskA second retry should be blocked")

        XCTAssertFalse(taskB.hasUsedNetworkRetry,
                       "taskB must not be affected by taskA's exhausted budget")
        XCTAssertTrue(taskB.attemptNetworkRetryAfterTransientError(),
                      "taskB should still have its full budget — per-instance, not shared")
    }

    // MARK: - Configuration

    /// The retry delay must match the watchdog's `default.retryDelay` so
    /// behaviour is consistent whether retry comes from this inline path or
    /// the (currently un-wired) `DownloadWatchdog` path.
    func testNetworkRetryDelay_matchesWatchdogDefault() {
        XCTAssertEqual(
            OpenAccessDownloadTask.NetworkRetryDelay,
            DownloadWatchdog.Configuration.default.retryDelay,
            "Inline retry delay must match the watchdog's default for consistent UX"
        )
    }

    /// The retry delay must be > 0 — a 0s delay would effectively be a
    /// busy-loop on whatever transient error the network layer just hit.
    func testNetworkRetryDelay_isPositive() {
        XCTAssertGreaterThan(
            OpenAccessDownloadTask.NetworkRetryDelay,
            0,
            "NetworkRetryDelay must be > 0 to give the network time to recover before re-fetching"
        )
    }

    // MARK: - Regression guard for HelpSpot 17725

    /// The fix-is-real test. Asserts the exact patron scenario fingerprint:
    /// a single transient network error mid-download must NOT kill the
    /// download — the retry budget kicks in. Pre-fix this returned false
    /// (no retry method existed) and the publisher got a terminal
    /// connectionLost error on the first blip.
    func testRegressionForBug_singleTransientErrorIsRetried_perHelpSpot17725() {
        let task = makeTask()

        // Simulate the network-layer arriving at the transient-error path
        // with the budget intact — this is exactly what the URLSession
        // delegate does on NSURLErrorTimedOut / NSURLErrorBadServerResponse
        // / NSURLErrorNetworkConnectionLost / etc.
        let didRetry = task.attemptNetworkRetryAfterTransientError()

        XCTAssertTrue(
            didRetry,
            "REGRESSION GUARD (HelpSpot 17725): a single transient network error mid-chunk-download must trigger an inline retry instead of publishing a terminal connectionLost error"
        )
    }
}
