//
//  OwnedSessionRegistryTests.swift
//  PalaceAudiobookToolkitTests
//
//  F2: the coordinator owns exactly ONE background URLSession per identifier
//  for the app's lifetime, so a reopened audiobook REUSES the live session a
//  prior download task created instead of spawning a duplicate with the same
//  (F1-stable) identifier — the duplicate is what iOS treats as undefined
//  behavior and what froze the reopened progress bar.
//
//  These tests pin the registry's GET-OR-CREATE + eviction contract (the part
//  that is unit-testable). The background-session DELEGATE lifecycle itself
//  (iOS delivering didWriteData / didFinishDownloadingTo across app suspension)
//  is NOT exercisable under XCTest and is covered by the on-device checklist.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class OwnedSessionRegistryTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AudiobookDownloadCoordinator.shared.clearAllState()
  }

  override func tearDown() {
    AudiobookDownloadCoordinator.shared.clearAllState()
    super.tearDown()
  }

  /// A plain (non-background) URLSession stands in for the real background
  /// session in these registry tests: the coordinator only stores and returns
  /// the instance it is handed, so identity is all that matters here. Using a
  /// real background session in a unit test is both unnecessary and flaky.
  private func makeSession(_ router: DurableSessionRouterDelegate) -> URLSession {
    URLSession(configuration: .default, delegate: router, delegateQueue: nil)
  }

  // MARK: - GET-OR-CREATE

  /// Same identifier -> same URLSession instance, and `configure` runs exactly
  /// ONCE. This is the core F2 guarantee: the reopened task reuses the live
  /// session rather than creating a second one under the shared identifier.
  func testSession_sameIdentifier_returnsSameInstanceAndConfiguresOnce() {
    let coordinator = AudiobookDownloadCoordinator.shared
    let identifier = "app.openAccessBackgroundIdentifier.reuse-same"

    var configureCount = 0
    let first = coordinator.session(forIdentifier: identifier) { router in
      configureCount += 1
      return self.makeSession(router)
    }
    let second = coordinator.session(forIdentifier: identifier) { router in
      configureCount += 1
      return self.makeSession(router)
    }

    XCTAssertTrue(first === second,
      "A repeated identifier must return the identical live session, not a duplicate")
    XCTAssertEqual(configureCount, 1,
      "The session must be created once and reused — a second create means a duplicate background session")

    first.invalidateAndCancel()
  }

  /// Distinct identifiers -> distinct URLSession instances, one `configure` per
  /// identifier. Guards against a registry that collapses different tracks/books
  /// onto one session.
  func testSession_distinctIdentifiers_returnDistinctInstances() {
    let coordinator = AudiobookDownloadCoordinator.shared
    let idA = "app.openAccessBackgroundIdentifier.track-A"
    let idB = "app.openAccessBackgroundIdentifier.track-B"

    var configureCount = 0
    let a = coordinator.session(forIdentifier: idA) { router in
      configureCount += 1
      return self.makeSession(router)
    }
    let b = coordinator.session(forIdentifier: idB) { router in
      configureCount += 1
      return self.makeSession(router)
    }

    XCTAssertFalse(a === b, "Different identifiers must map to different sessions")
    XCTAssertEqual(configureCount, 2, "Each distinct identifier configures its own session")

    a.invalidateAndCancel()
    b.invalidateAndCancel()
  }

  // MARK: - Eviction (cancel / retry paths)

  /// After `discardOwnedSession`, the next `session(forIdentifier:)` for the
  /// same identifier CREATES A FRESH session (configure runs again) — a prior
  /// invalidated session is never handed back out. This is what makes the
  /// explicit-cancel and token-refresh/network-retry paths safe: they evict,
  /// then re-fetch builds a new session.
  func testDiscard_thenSession_createsFreshInstance() {
    let coordinator = AudiobookDownloadCoordinator.shared
    let identifier = "app.overdriveBackgroundIdentifier.evict-refetch"

    var configureCount = 0
    let original = coordinator.session(forIdentifier: identifier) { router in
      configureCount += 1
      return self.makeSession(router)
    }

    coordinator.discardOwnedSession(forIdentifier: identifier)

    let replacement = coordinator.session(forIdentifier: identifier) { router in
      configureCount += 1
      return self.makeSession(router)
    }

    XCTAssertFalse(original === replacement,
      "After eviction, a re-fetch must build a NEW session — reusing the invalidated one would silently drop callbacks")
    XCTAssertEqual(configureCount, 2,
      "Eviction must clear the cache so the next fetch reconfigures")

    replacement.invalidateAndCancel()
  }

  /// Discarding an identifier that was never created is a no-op (no crash, no
  /// spurious state). Exercises the cancel path firing before any download
  /// started for that task.
  func testDiscard_unknownIdentifier_isNoOp() {
    let coordinator = AudiobookDownloadCoordinator.shared
    coordinator.discardOwnedSession(forIdentifier: "never-created")

    var configured = false
    let session = coordinator.session(forIdentifier: "never-created") { router in
      configured = true
      return self.makeSession(router)
    }
    XCTAssertTrue(configured,
      "Discarding a never-created identifier must not leave a phantom entry that suppresses the real create")
    session.invalidateAndCancel()
  }

  // MARK: - Retain cycle (architect SoD blocker — the mutant-killer)

  /// F2 makes a download task strongly retain its `DownloadTaskURLSessionDelegate`
  /// (`sessionDelegate`), and the delegate holds the task back. If that back-ref
  /// were strong, task⇄delegate would be a self-retaining cycle that never breaks
  /// on player close — leaking the pair AND keeping the router's weak observer
  /// alive, which would make the no-observer durable-completion fallback
  /// unreachable via close. The back-ref is `weak`, so dropping every external
  /// strong ref must dealloc BOTH. This asserts exactly that.
  ///
  /// Mutation coverage: flip the delegate's `weak var downloadTask` back to a
  /// strong `let`/`var` and this test fails (the sentinels stay non-nil).
  func testTaskAndDelegate_deallocateWhenExternalRefsDropped_noRetainCycle() {
    weak var weakTask: OpenAccessDownloadTask?
    weak var weakDelegate: DownloadTaskURLSessionDelegate?

    autoreleasepool {
      let url = URL(string: "https://example.com/chapter.mp3")!
      let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cycle-dest.mp3")

      let task = OpenAccessDownloadTask(
        key: "cycle-track",
        bookID: "cycle-book",
        downloadURL: url,
        urlString: url.absoluteString,
        urlMediaType: .audioMPEG,
        alternateLinks: nil,
        feedbooksProfile: nil,
        token: nil
      )
      let delegate = DownloadTaskURLSessionDelegate(
        downloadTask: task,
        statePublisher: task.statePublisher,
        finalDirectory: dest,
        trackKey: task.key
      )
      // Reproduce production ownership: the task strongly retains its delegate,
      // exactly as `downloadAsset` does. The delegate's back-ref to the task is
      // the thing under test.
      task.installSessionDelegateForTesting(delegate)

      weakTask = task
      weakDelegate = delegate

      // Sanity: both alive while the local strong refs exist.
      XCTAssertNotNil(weakTask)
      XCTAssertNotNil(weakDelegate)
    }

    // External strong refs (the locals) are gone. With a weak back-reference the
    // cycle is broken, so both must have deallocated.
    XCTAssertNil(weakTask,
      "The download task must deallocate when external refs drop — a strong delegate back-ref would leak it")
    XCTAssertNil(weakDelegate,
      "The session delegate must deallocate with its task — otherwise the router's weak observer never nils and Refinement 1 is unreachable on close")
  }

  // MARK: - Observer swap (thread-safety smoke)

  /// `registerObserver` for an identifier with a live session must not crash and
  /// must be safe to call repeatedly (each open re-registers). Concurrent swaps
  /// exercise the router's lock — a data race here would trip TSan / crash.
  func testRegisterObserver_concurrentSwaps_areSafe() {
    let coordinator = AudiobookDownloadCoordinator.shared
    let identifier = "app.openAccessBackgroundIdentifier.observer-swap"

    let session = coordinator.session(forIdentifier: identifier) { router in
      self.makeSession(router)
    }

    // Keep strong refs so the weak observer isn't collected mid-loop; the point
    // is that concurrent setCurrentObserver calls don't race.
    let observers = (0..<8).map { _ in RecordingObserver() }
    let group = DispatchGroup()
    for observer in observers {
      DispatchQueue.global().async(group: group) {
        for _ in 0..<50 {
          coordinator.registerObserver(observer, forIdentifier: identifier)
        }
      }
    }
    let finished = group.wait(timeout: .now() + 5)
    XCTAssertEqual(finished, .success, "Concurrent observer swaps must complete without deadlock")

    session.invalidateAndCancel()
  }
}

// MARK: - Test double

/// Minimal `DownloadTaskObserver` that records nothing — used only to have a
/// concrete AnyObject the router can hold weakly during the swap-safety test.
private final class RecordingObserver: DownloadTaskObserver {
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {}
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {}
}
