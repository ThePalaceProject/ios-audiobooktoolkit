//
//  OverdriveTrackDurationTests.swift
//  PalaceAudiobookToolkitTests
//
//  Duration-resolution contracts for `OverdriveTrack` (PP-4724 Wave 3).
//
//  This file exists because `OverdriveTrack` produced three defects in three
//  consecutive review passes and every one of them was found by reading the
//  code, never by running it — there was no test anywhere in the repository
//  that referenced the type. The defects were:
//
//    1. A load that SUCCEEDED but returned NaN/0 (a `CMTime.indefinite`, or a
//       zero-length file) was marked `.resolved`, latching the track at
//       duration 0 permanently. Covered by
//       `testUnusableResult_IsTreatedAsFailureNotResolution`.
//    2. The retry bound never bound anything: the claim matched
//       `.failed(attempts)` and wrote back a plain `.loading`, discarding the
//       count, so the failure handler always rewrote `attempts: 1`. Covered by
//       `testRepeatedFailure_StopsAtTheAttemptBound`.
//    3. `allowOneMoreResolution()` had zero callers; the download-completion
//       sink wrote `.idle` directly, clobbering a load already in flight over a
//       partially-written file. Covered by
//       `testDownloadCompletingMidLoad_DoesNotLatchThePartialValue`.
//
//  All are mutation-verified — the defect was reintroduced and the test
//  confirmed to fail. See the note on each test for what specifically was
//  reverted and what the test reported.
//
//  Honest score: EIGHT mutants are killed, but only SIX of them are reachable
//  in production. The two that guard `claimDurationLoad`'s `.resolved` refusal
//  (`M2`, `M7`) die only through a direct `requestDurationUpdate()`, which no
//  production code calls: the getter early-returns on any non-zero duration and
//  the completion sink resets to `.idle` first, so `.resolved` is never the
//  state a real claim meets. They are worth keeping — they pin the claim's own
//  contract — but "8/8 killed" would overstate the coverage of shipping paths.
//
//  A fourth defect was found by review AFTER these tests were written, in the
//  transition they introduced: a completion arriving during the final permitted
//  attempt had its re-arm discarded when that attempt failed, stranding a
//  fully-downloaded track at duration 0. Covered by
//  `testCompletionDuringTheFinalAttempt_DoesNotStrandTheTrack`.
//
//  Testing any of this at all required a seam: `updateDuration` used to build
//  its `AVURLAsset` inline, so there was no way to make a load fail, hang, or
//  return NaN on demand, and no way to count how many times it ran. The
//  injected `TrackDurationLoader` is that seam.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest

@testable import PalaceAudiobookToolkit

final class OverdriveTrackDurationTests: XCTestCase {
  private var stagedAssetURLs: [URL] = []

  override func tearDown() {
    for url in stagedAssetURLs {
      try? FileManager.default.removeItem(at: url)
    }
    stagedAssetURLs.removeAll()
    super.tearDown()
  }

  // MARK: - Fixtures

  /// Counts loader invocations and serves a scripted result per call, so a test
  /// can assert both *what* was resolved and *how many times* the file was read.
  private final class LoaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _settled = 0
    private let script: @Sendable (Int) async throws -> TimeInterval

    /// - Parameter script: receives the 1-based invocation number.
    init(script: @escaping @Sendable (Int) async throws -> TimeInterval) {
      self.script = script
    }

    /// Attempts STARTED.
    var calls: Int { lock.withLock { _calls } }

    /// Attempts that have RETURNED (or thrown).
    ///
    /// Distinct from `calls` on purpose. Waiting on `calls` only tells you an
    /// attempt entered the loader, and a test that then drives the machine is
    /// racing the attempt still in flight — which is exactly how
    /// `testDownloadCompleting_ReArmsAnExhaustedRetryBudget` could send
    /// `.completed` underneath its own final attempt and go red on a loaded
    /// machine while passing on an idle one.
    var settled: Int { lock.withLock { _settled } }

    var loader: TrackDurationLoader {
      { [self] _ in
        let n = lock.withLock { () -> Int in
          _calls += 1
          return _calls
        }
        defer { lock.withLock { _settled += 1 } }
        return try await script(n)
      }
    }
  }

  private struct LoadFailed: Error {}

  private func makeManifest() throws -> Manifest {
    try Manifest.from(
      jsonFileName: ManifestJSON.animalFarm.rawValue,
      bundle: Bundle(for: type(of: self))
    )
  }

  /// A track whose download task maps to a unique on-disk path (the filename is
  /// a hash of `bookID` + url), so tests cannot collide with one another.
  private func makeTrack(
    manifestDuration: Double = 0,
    loader: @escaping TrackDurationLoader
  ) throws -> OverdriveTrack {
    let manifest = try makeManifest()
    return try OverdriveTrack(
      manifest: manifest,
      urlString: "https://example.invalid/\(UUID().uuidString).mp3",
      audiobookID: "overdrive-duration-\(UUID().uuidString)",
      title: "Track 1",
      duration: manifestDuration,
      index: 0,
      key: nil,
      durationLoader: loader
    )
  }

  /// Puts a file where the track's download task expects its asset, so
  /// `updateDuration`'s `fileExists` gate opens.
  @discardableResult
  private func stageAsset(for track: OverdriveTrack) throws -> URL {
    guard let assetURL = (track.downloadTask as? OverdriveDownloadTask)?.localDirectory() else {
      throw XCTSkip("Could not resolve the task's local asset URL.")
    }
    try FileManager.default.createDirectory(
      at: assetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: assetURL.path, contents: Data("audio".utf8))
    stagedAssetURLs.append(assetURL)
    return assetURL
  }

  /// Reads `duration` repeatedly until `condition` holds or the deadline
  /// passes. Each read is what drives the state machine, so this is the test's
  /// "run the thing" step, not merely a wait.
  ///
  /// - Returns: whether the condition was met.
  @discardableResult
  private func pumpDuration(
    _ track: OverdriveTrack,
    until condition: () -> Bool,
    timeout: TimeInterval = 5.0
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() {
        return true
      }
      _ = track.duration
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
  }

  /// Runs the run loop without driving the machine, so anything already in
  /// flight can land. Needed for "and then nothing further changes" assertions,
  /// which cannot be expressed as a wait-for-condition: the value being watched
  /// for may appear transiently and then be overwritten, which is precisely the
  /// defect `testDownloadCompletingMidLoad_DoesNotLatchThePartialValue` covers.
  private func settle(_ duration: TimeInterval = 0.5) {
    RunLoop.current.run(until: Date().addingTimeInterval(duration))
  }

  // MARK: - The reload-storm gate

  /// Before any file exists on disk, reading `duration` must not start a load.
  ///
  /// This is the gate whose absence was the original reload storm:
  /// `localDirectory()` returns a path whether or not a file is there, so
  /// without the `fileExists` check every read claimed a load, failed, released
  /// the claim, and let the next read claim again — and `Tracks.totalDuration`
  /// reduces `duration` over every track on each UI refresh.
  ///
  /// Mutation-verified: dropping the `fileExists` clause from `updateDuration`'s
  /// guard makes this report 1 call instead of 0, and a duration of 42.0 instead of 0.
  func testBeforeDownload_NeverAsksTheLoader() throws {
    let spy = LoaderSpy(script: { _ in 42.0 })
    let track = try makeTrack(loader: spy.loader)

    for _ in 0 ..< 200 {
      _ = track.duration
    }

    XCTAssertEqual(spy.calls, 0, "No file on disk means there is nothing to read.")
    XCTAssertEqual(track.duration, 0)
  }

  /// A manifest that already states the duration is authoritative until the
  /// download completes; reading must not touch the file system at all.
  ///
  /// Mutation-verified twice: dropping `durationLoad.value = .resolved` from
  /// `init` makes this report 1 call instead of 0 and a duration of 42.0
  /// instead of 123.0; removing the `.resolved` arm from `claimDurationLoad`'s
  /// refusal list makes it report 200 calls instead of 0.
  func testManifestSuppliedDuration_NeverAsksTheLoader() throws {
    let spy = LoaderSpy(script: { _ in 42.0 })
    let track = try makeTrack(manifestDuration: 123.0, loader: spy.loader)
    try stageAsset(for: track)

    for _ in 0 ..< 200 {
      _ = track.duration
      // As above: the getter short-circuits on a non-zero duration, so only the
      // explicit refresh path can reach the state machine at all.
      track.requestDurationUpdate()
    }
    settle()

    XCTAssertEqual(track.duration, 123.0)
    XCTAssertEqual(spy.calls, 0, "The manifest already answered; no asset load is warranted.")
  }

  /// Once a usable duration resolves, further reads are answered from memory.
  ///
  /// Mutation-verified: removing the `.resolved` arm from `claimDurationLoad`'s
  /// refusal list makes this report 201 calls instead of 1.
  func testSuccessfulLoad_AsksExactlyOnceAcrossManyReads() throws {
    let spy = LoaderSpy(script: { _ in 321.0 })
    let track = try makeTrack(loader: spy.loader)
    try stageAsset(for: track)

    XCTAssertTrue(
      pumpDuration(track, until: { spy.calls >= 1 }),
      "The staged file should have been read."
    )
    for _ in 0 ..< 200 {
      _ = track.duration
      // Reads alone cannot reach the claim once a duration is resolved — the
      // getter early-returns on any non-zero value, so it never asks. Drive
      // the refresh entry point directly, or the `.resolved` refusal is never
      // actually exercised and a mutant that deletes it survives.
      track.requestDurationUpdate()
    }
    settle()

    XCTAssertEqual(track.duration, 321.0)
    XCTAssertEqual(spy.calls, 1, "A resolved duration must not be re-read.")
  }

  // MARK: - The retry bound

  /// A file that is present but unreadable must stop being retried.
  ///
  /// This is the test for the defect that mattered most, because the bound
  /// LOOKED present and did nothing: `claimDurationLoad` matched
  /// `.failed(attempts)` and then wrote a plain `.loading`, throwing the count
  /// away, so `recordDurationLoadFailure` always saw `.loading`, always took its
  /// "first failure" branch, and always wrote `attempts: 1`. `attempts < 3` was
  /// therefore always true and the retry was unbounded — the very storm the
  /// surrounding code claims to bound.
  ///
  /// Mutation-verified: restoring the count-discarding claim
  /// (`state = .loading(priorFailures: 0, supersededByCompletion: false)` in the
  /// `.failed` arm) makes this fail with 303 calls against an expected 3.
  func testRepeatedFailure_StopsAtTheAttemptBound() throws {
    let spy = LoaderSpy(script: { _ in throw LoadFailed() })
    let track = try makeTrack(loader: spy.loader)
    try stageAsset(for: track)

    XCTAssertTrue(
      pumpDuration(track, until: { spy.calls >= 3 }),
      "Expected the bounded number of attempts to be spent, saw \(spy.calls)."
    )

    // Keep asking well past the bound. Nothing more may happen.
    for _ in 0 ..< 300 {
      _ = track.duration
      RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }

    XCTAssertEqual(spy.calls, 3, "Three attempts is the bound; reads after it must be refused.")
    XCTAssertEqual(track.duration, 0, "An unreadable file leaves the duration unresolved.")
  }

  /// A load that SUCCEEDS but yields nothing usable is a failure, not a
  /// resolution. `CMTime.indefinite` converts to NaN and a zero-length or
  /// still-being-written file converts to 0; marking either `.resolved` latches
  /// the track at duration 0 forever, because the getter then sees `<= 0`, asks
  /// again, and is refused. Patron-visible through `Tracks.totalDuration` as a
  /// wrong total time and a wrong scrubber range.
  ///
  /// Mutation-verified: replacing the `seconds.isFinite, seconds > 0` guard with
  /// an unconditional `completeDurationLoad(seconds:)` makes this fail
  /// with `nan` reaching the caller as a duration and only 1 attempt spent.
  func testUnusableResult_IsTreatedAsFailureNotResolution() throws {
    let spy = LoaderSpy(script: { n in n == 1 ? .nan : 0.0 })
    let track = try makeTrack(loader: spy.loader)
    try stageAsset(for: track)

    XCTAssertTrue(
      pumpDuration(track, until: { spy.calls >= 3 }),
      "NaN and 0 must be retried like any other failure, saw \(spy.calls) attempts."
    )

    XCTAssertEqual(track.duration, 0)
    XCTAssertFalse(track.duration.isNaN, "NaN must never reach callers as a duration.")
  }

  // MARK: - Download completion

  /// `fileExists` does not mean "file is complete". The shared download
  /// delegate routes through `MediaProcessor.optimizeQTFile` when a file needs
  /// optimizing, and that creates a ZERO-BYTE file at the final url and then
  /// writes it progressively — so a load started in that window reads a partial
  /// file and can come back with a short-but-finite duration.
  ///
  /// If that value latched `.resolved`, the track would report the wrong
  /// duration for the rest of the process. It must not: completion supersedes
  /// the in-flight load's answer and the finished file is read again.
  ///
  /// Mutation-verified: restoring the sink's direct `durationLoad.value = .idle`
  /// write (which clobbers `.loading` instead of marking it superseded) makes
  /// this fail with a settled duration of 12.0 instead of 900.0 — the partial
  /// value, latched.
  func testDownloadCompletingMidLoad_DoesNotLatchThePartialValue() throws {
    let firstLoadEntered = expectation(description: "partial-file load started")
    let releaseFirstLoad = expectation(description: "partial-file load released")

    let spy = LoaderSpy(script: { n in
      if n == 1 {
        firstLoadEntered.fulfill()
        // Hold the partial-file read open so completion lands underneath it.
        await Self.awaitFulfillment(of: releaseFirstLoad)
        return 12.0 // what a half-written file reports
      }
      return 900.0 // what the finished file reports
    })

    let track = try makeTrack(loader: spy.loader)
    try stageAsset(for: track)

    _ = track.duration
    wait(for: [firstLoadEntered], timeout: 5.0)

    // The download finishes while the first load is still reading.
    (track.downloadTask as? OverdriveDownloadTask)?.statePublisher.send(.completed)

    releaseFirstLoad.fulfill()

    XCTAssertTrue(
      pumpDuration(track, until: { spy.calls >= 2 }),
      "Expected the finished file to be re-read; calls \(spy.calls)."
    )
    // Settle before reading. Asserting on the first sighting of 900 would pass
    // against the clobbering version too: there the two loads run CONCURRENTLY,
    // the finished-file load lands first, and the partial answer overwrites it
    // a moment later. Only the value that survives is evidence.
    settle()

    XCTAssertEqual(
      track.duration, 900.0,
      "The finished file's duration must be the one that stands, not the partial file's."
    )
    XCTAssertEqual(spy.calls, 2, "Exactly one re-read: the partial answer, then the real one.")
  }

  /// Failures accumulated against a file that was still being written must not
  /// count against the finished one. Completion re-arms the budget.
  ///
  /// Mutation-verified: removing the `else { state = .idle }` arm from
  /// `noteDownloadCompleted()` makes this fail with the duration stuck at 0.0 after 3 calls — the loader is never asked a fourth time.
  func testDownloadCompleting_ReArmsAnExhaustedRetryBudget() throws {
    let spy = LoaderSpy(script: { n in
      if n <= 3 {
        throw LoadFailed()
      }
      return 555.0
    })
    let track = try makeTrack(loader: spy.loader)
    try stageAsset(for: track)

    // Gate on attempts that have RETURNED, not merely started. Waiting on
    // `calls` lets `.completed` be sent while the third attempt is still in
    // flight, which is a different scenario entirely (see
    // `testCompletionDuringTheFinalAttempt_DoesNotStrandTheTrack`) and made
    // this test's outcome depend on machine load.
    XCTAssertTrue(
      pumpDuration(track, until: { spy.settled >= 3 }),
      "Expected the budget to be spent first, saw \(spy.settled) settled of \(spy.calls) started."
    )
    XCTAssertEqual(track.duration, 0, "Precondition: the budget is exhausted and nothing resolved.")

    (track.downloadTask as? OverdriveDownloadTask)?.statePublisher.send(.completed)

    XCTAssertTrue(
      pumpDuration(track, until: { track.duration == 555.0 }),
      "A completed download must re-arm the budget; duration is \(track.duration), calls \(spy.calls)."
    )
  }

  /// A completion arriving DURING the final permitted attempt, where that
  /// attempt then fails, must not strand the track.
  ///
  /// This is the interleaving that `.completed`-marks-superseded created and
  /// that nothing covered. `noteDownloadCompleted` converts `.loading(2, false)`
  /// into `.loading(2, true)` — the completion's re-arm is now carried by the
  /// flag rather than by a state change, and the sink's own `updateDuration()`
  /// is refused because a load is already in flight. If the failure handler then
  /// charges that attempt to the budget, the flag is discarded, the budget
  /// reaches its limit, and every later claim is refused: a fully-downloaded
  /// track reports duration 0 for the rest of the session. The completion has to
  /// win over the failure.
  ///
  /// Mutation-verified: replacing the `supersededByCompletion: true` arm of
  /// `recordDurationLoadFailure` with the ordinary
  /// `state = .failed(attempts: priorFailures + 1)` strands the track — it
  /// reports duration 0.0 with the loader never asked a fourth time.
  func testCompletionDuringTheFinalAttempt_DoesNotStrandTheTrack() throws {
    let finalAttemptEntered = expectation(description: "final permitted attempt started")
    let releaseFinalAttempt = expectation(description: "final permitted attempt released")

    let spy = LoaderSpy(script: { n in
      if n < 3 {
        throw LoadFailed()
      }
      if n == 3 {
        // The last attempt the budget permits. Hold it open so completion lands
        // underneath it, then fail it.
        finalAttemptEntered.fulfill()
        await Self.awaitFulfillment(of: releaseFinalAttempt)
        throw LoadFailed()
      }
      return 777.0
    })

    let track = try makeTrack(loader: spy.loader)
    try stageAsset(for: track)

    XCTAssertTrue(
      pumpDuration(track, until: { spy.calls >= 3 }, timeout: 10.0),
      "Expected to reach the final permitted attempt, saw \(spy.calls)."
    )
    wait(for: [finalAttemptEntered], timeout: 5.0)

    // Completion lands while that attempt is still running.
    (track.downloadTask as? OverdriveDownloadTask)?.statePublisher.send(.completed)
    releaseFinalAttempt.fulfill()

    XCTAssertTrue(
      pumpDuration(track, until: { track.duration == 777.0 }, timeout: 10.0),
      "A completion during the final attempt must survive that attempt's failure; "
        + "duration is \(track.duration) after \(spy.calls) calls."
    )
  }

  // MARK: - Helpers

  /// Suspends until `expectation` is fulfilled, without blocking a thread.
  private static func awaitFulfillment(of expectation: XCTestExpectation) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        _ = XCTWaiter().wait(for: [expectation], timeout: 10.0)
        continuation.resume()
      }
    }
  }
}
