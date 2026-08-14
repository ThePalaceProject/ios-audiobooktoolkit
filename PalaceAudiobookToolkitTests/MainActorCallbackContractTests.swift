//
//  MainActorCallbackContractTests.swift
//  PalaceAudiobookToolkitTests
//
//  Every public completion on `DefaultAudiobookManager` must be delivered on the
//  main actor.
//
//  This is not a style preference. The app's `AudiobookSessionManager` is
//  `@MainActor`, so a closure it passes in is main-actor-isolated. Calling it
//  from a `Task`'s cooperative executor makes Swift's isolation check fail the
//  PROCESS: `dispatch_assert_queue_fail` -> `EXC_BREAKPOINT` / `SIGTRAP`. There
//  is no error and no unwinding — the app is simply gone, and the patron's
//  position is not saved on the way out.
//
//  PP-4955: reproduced on device by scrubbing a Findaway audiobook. Three crash
//  reports inside one minute on build 493 / iOS 26.6, all the same signature:
//
//      dispatch_assert_queue_fail
//      swift_task_checkIsolatedSwift
//      closure #1 in AudiobookSessionManager.seek(to:)
//      closure #2 in DefaultAudiobookManager.seekWithSlider(value:completion:)
//
//  WHY NOTHING CAUGHT IT. `seekWithSlider` branches on the player type. The
//  BOTH branches were unsafe, though only one crashed reproducibly. The `else`
//  branch — Findaway, Overdrive, LCP — called back from a `Task`'s cooperative
//  executor every time, so it crashed deterministically. The `OpenAccessPlayer`
//  branch was ASSUMED safe because open-access titles did not crash; that was an
//  inference from absence. It bottoms out in
//  `AVPlayerItem.seek(to:completionHandler:)`, whose handler AVFoundation
//  documents as running on an ARBITRARY queue — so it is the same defect, merely
//  timing-dependent. Both branches now hop.
//
//  Note what was and was NOT the gap. Findaway *manifest* fixtures do exist here
//  (`secret_lives`, `dune_oversubdivided`) — an earlier version of this comment
//  claimed otherwise and was wrong. The gap was the *player*: every test builds
//  an `OpenAccessAudiobook`, so the branch selection — which keys off player
//  type, not manifest type — always went the safe way.
//
//  These tests reach it with no device and no DRM, because the `else` branch is
//  taken by ANY player that is not an `OpenAccessPlayer` — including `PlayerMock`.
//  That is the whole point: the crashing path is ordinary Swift, and the thing
//  that made it invisible was fixture selection, not platform.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest

@testable import PalaceAudiobookToolkit

final class MainActorCallbackContractTests: XCTestCase {

  /// A manager whose player is NOT an `OpenAccessPlayer`, so the DRM-shaped
  /// branch is the one under test, with a non-nil `currentChapter` so the
  /// synchronous early-return guard is not what answers.
  ///
  /// Run against BOTH an open-access and a Findaway manifest.
  ///
  /// The open-access one is not redundant — it is the control. The Findaway one
  /// is the data that actually crashed on device, and a reviewer measured
  /// `secret_lives` as the fixture where 9 of 10 chapters resolve differently
  /// under the boundary tie-break, so it is the closest thing the suite has to
  /// the real thing. (Note the *player* is what selects the crashing branch, not
  /// the manifest — but matching the data keeps the test honest about what it
  /// stands in for.)
  private static let manifests: [ManifestJSON] = [.alice, .secretLives]

  private func makeManager(
    _ which: ManifestJSON
  ) throws -> (DefaultAudiobookManager, PlayerMock) {
    let manifest = try Manifest.from(
      jsonFileName: which.rawValue, bundle: Bundle(for: type(of: self))
    )
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(
        manifest: manifest, bookIdentifier: "pp4955-main-actor", decryptor: nil, token: nil
      )
    )
    let player = PlayerMock(tableOfContents: audiobook.tableOfContents)

    // Preconditions that keep these tests honest. If `currentChapter` were nil,
    // `seekWithSlider` would call `completion(nil)` SYNCHRONOUSLY on the calling
    // thread — which is already main in a test — and the assertion would pass
    // without ever reaching the code that crashed.
    let firstChapter = try XCTUnwrap(audiobook.tableOfContents.toc.first)
    player.currentChapter = firstChapter
    player.currentTrackPosition = firstChapter.position
    audiobook.player = player

    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "PP-4955", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )

    XCTAssertFalse(
      manager.audiobook.player is OpenAccessPlayer,
      "Precondition: the player must NOT be an OpenAccessPlayer, or the safe branch is taken "
        + "and this test proves nothing about the branch that crashed."
    )
    XCTAssertNotNil(
      manager.currentChapter,
      "Precondition: currentChapter must be non-nil, or seekWithSlider returns synchronously."
    )
    return (manager, player)
  }

  /// The crash itself. Mutation-verified: reverting the `await MainActor.run`
  /// in `seekWithSlider`'s `else` branch makes this fail with
  /// `completion arrived off the main actor` — the exact condition that traps
  /// the process in the app.
  func testSeekWithSlider_deliversCompletionOnTheMainActor() throws {
    for which in Self.manifests {
      let (manager, _) = try makeManager(which)
    let delivered = expectation(description: "seekWithSlider completion \(which.rawValue)")
    var wasMain: Bool?

    manager.seekWithSlider(value: 0.5) { _ in
      wasMain = Thread.isMainThread
      delivered.fulfill()
    }

    wait(for: [delivered], timeout: 5.0)
    XCTAssertEqual(
      wasMain, true,
      "[\(which.rawValue)] " +
      "seekWithSlider completion arrived off the main actor. In the app this is not a warning — "
        + "the @MainActor caller's closure trips Swift's isolation check and the process is killed."
    )
    }
  }

  /// Same defect, same file. Worth its own test because its documentation claims
  /// it exists *for* `@MainActor` hosts under strict concurrency — the exact
  /// contract it was breaking.
  func testPlayAtPosition_deliversCompletionOnTheMainActor() throws {
    let (manager, _) = try makeManager(.secretLives)
    let position = try XCTUnwrap(manager.currentChapter?.position)
    let delivered = expectation(description: "playAtPosition completion")
    var wasMain: Bool?

    manager.playAtPosition(position) { _ in
      wasMain = Thread.isMainThread
      delivered.fulfill()
    }

    wait(for: [delivered], timeout: 5.0)
    XCTAssertEqual(wasMain, true, "playAtPosition completion arrived off the main actor.")
  }

  /// Third instance of the same shape.
  func testSkipPlayhead_deliversCompletionOnTheMainActor() throws {
    let (manager, _) = try makeManager(.secretLives)
    let delivered = expectation(description: "skipPlayhead completion")
    var wasMain: Bool?

    manager.skipPlayhead(30) { _ in
      wasMain = Thread.isMainThread
      delivered.fulfill()
    }

    wait(for: [delivered], timeout: 5.0)
    XCTAssertEqual(wasMain, true, "skipPlayhead completion arrived off the main actor.")
  }

  /// Guards the assumption the other three rest on: that a mock player really
  /// does take the DRM-shaped branch. If `PlayerMock` ever became an
  /// `OpenAccessPlayer` subclass, the three tests above would keep passing while
  /// silently testing the branch that was never broken.
  func testMockPlayerTakesTheNonOpenAccessBranch() throws {
    let (manager, player) = try makeManager(.secretLives)
    XCTAssertFalse(manager.audiobook.player is OpenAccessPlayer)
    XCTAssertTrue(manager.audiobook.player === player)
  }
}
