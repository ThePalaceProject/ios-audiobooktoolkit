//
//  AudiobookDownloadCoordinatorRenameTests.swift
//  PalaceAudiobookToolkitTests
//
//  Pins the `AudiobookSessionManager` -> `AudiobookDownloadCoordinator` rename
//  (swarm_efd1f0c3 / T3) against an accidental revert.
//
//  The rename itself is enforced by the compiler -- every consumer
//  (`OpenAccessBackgroundListener`, `OverdriveBackgroundListener`) is updated
//  atomically, so a failing build IS the regression gate. This file adds one
//  behavioral sanity test that exercises the renamed type's real logic
//  (register -> query by bookID round-trip), so a future refactor that
//  silently breaks `activeDownloads(forBookID:)` is caught here.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class AudiobookDownloadCoordinatorRenameTests: XCTestCase {

  override func setUp() {
    super.setUp()
    AudiobookDownloadCoordinator.shared.clearAllState()
  }

  override func tearDown() {
    AudiobookDownloadCoordinator.shared.clearAllState()
    super.tearDown()
  }

  /// Registers two downloads under the same bookID and asserts
  /// `activeDownloads(forBookID:)` returns both -- proves the renamed type's
  /// dictionary store + filter path still works end-to-end after the rename.
  func testRegisterActiveDownload_thenQueryByBookID_returnsRegisteredEntries() {
    let bookID = "book-T3-rename"
    let session1 = "session-1"
    let session2 = "session-2"
    let url = URL(string: "https://example.com/chapter.mp3")!
    let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dest.mp3")

    AudiobookDownloadCoordinator.shared.registerActiveDownload(
      sessionIdentifier: session1,
      bookID: bookID,
      trackKey: "track-1",
      originalURL: url,
      localDestination: dest
    )
    AudiobookDownloadCoordinator.shared.registerActiveDownload(
      sessionIdentifier: session2,
      bookID: bookID,
      trackKey: "track-2",
      originalURL: url,
      localDestination: dest
    )

    // The register path is dispatched via a barrier on a private serial queue.
    // A sync read on `activeDownloads(forBookID:)` flushes pending barrier
    // writes, so this query reflects both registrations.
    let downloads = AudiobookDownloadCoordinator.shared.activeDownloads(forBookID: bookID)

    XCTAssertEqual(downloads.count, 2)
    XCTAssertEqual(Set(downloads.map(\.sessionIdentifier)), [session1, session2])
    XCTAssertEqual(Set(downloads.map(\.trackKey)), ["track-1", "track-2"])
    XCTAssertTrue(downloads.allSatisfy { $0.bookID == bookID })
  }
}
