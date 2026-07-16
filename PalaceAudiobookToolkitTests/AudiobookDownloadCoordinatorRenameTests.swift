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

  // MARK: - F1: background-completion finalization (PP-4800 root cause)

  /// When a track download is registered (as `OverdriveDownloadTask.downloadAsset`
  /// now does), a background completion delivered after the app was killed is
  /// finalized: the temp file is MOVED to the track's destination. This is the
  /// mechanism the F1 fix relies on — wiring `registerActiveDownload` is what
  /// makes `activeDownloads[id]` non-empty so this branch runs.
  func testBackgroundCompletion_whenRegistered_movesTempFileToDestination() throws {
    let coordinator = AudiobookDownloadCoordinator.shared
    let bookID = "book-F1-finalize"
    let session = "app.overdriveBackgroundIdentifier.f1-finalize-stable"
    let url = URL(string: "https://ofsdirect.api.overdrive.com/track-1.mp3")!

    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("F1FinalizeTest", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let destination = dir.appendingPathComponent("final-track.mp3")
    let downloadedTemp = dir.appendingPathComponent("downloaded.tmp")
    XCTAssertTrue(FileManager.default.createFile(atPath: downloadedTemp.path,
                                                 contents: Data("audio-bytes".utf8)))

    coordinator.registerActiveDownload(
      sessionIdentifier: session, bookID: bookID, trackKey: "track-1",
      originalURL: url, localDestination: destination)

    coordinator.handleBackgroundDownloadCompletion(
      sessionIdentifier: session, downloadedFileURL: downloadedTemp, originalURL: url)

    // Flush the coordinator's barrier queue with a sync read before asserting.
    _ = coordinator.activeDownloads(forBookID: bookID)

    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
      "A registered download must be finalized to its destination on background completion")
    XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedTemp.path),
      "The temp file must be moved, not left behind")
    XCTAssertEqual(try? String(contentsOf: destination, encoding: .utf8), "audio-bytes")

    try? FileManager.default.removeItem(at: dir)
  }

  /// Documents the F1 defect the fix closes: with NO registration (the pre-fix
  /// state where `registerActiveDownload` was never called in production), the
  /// coordinator has no destination and cannot finalize — so the finished file
  /// is not moved anywhere and is lost when iOS reclaims the temp file.
  func testBackgroundCompletion_whenNotRegistered_cannotFinalize() throws {
    let coordinator = AudiobookDownloadCoordinator.shared
    let session = "app.overdriveBackgroundIdentifier.f1-unregistered"
    let url = URL(string: "https://ofsdirect.api.overdrive.com/orphan.mp3")!

    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("F1UnregisteredTest", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let downloadedTemp = dir.appendingPathComponent("downloaded.tmp")
    XCTAssertTrue(FileManager.default.createFile(atPath: downloadedTemp.path,
                                                 contents: Data("audio-bytes".utf8)))

    // No registerActiveDownload — the pre-fix production behavior.
    coordinator.handleBackgroundDownloadCompletion(
      sessionIdentifier: session, downloadedFileURL: downloadedTemp, originalURL: url)
    _ = coordinator.activeDownloads(forBookID: "any")  // flush

    XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedTemp.path),
      "Without a registered download the coordinator has no destination and cannot finalize — the F1 gap the fix closes by wiring registerActiveDownload in downloadAsset")

    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - Prune completed entries (F1 fast-follow — both reviewers flagged)

  /// After a background completion finalizes the file, the entry must be
  /// PRUNED from `activeDownloads` — not left `.completed`. Without pruning,
  /// every finished download reloads forever on each launch (unbounded growth,
  /// no production `removeActiveDownload` caller). Asserts both: (a) the file
  /// is at its destination, and (b) the entry no longer appears for the book.
  func testBackgroundCompletion_whenRegistered_prunesEntryAfterFinalizing() throws {
    let coordinator = AudiobookDownloadCoordinator.shared
    let bookID = "book-prune-after-complete"
    let session = "app.overdriveBackgroundIdentifier.prune-stable"
    let url = URL(string: "https://ofsdirect.api.overdrive.com/track-1.mp3")!

    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("PruneAfterCompleteTest", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let destination = dir.appendingPathComponent("final-track.mp3")
    let downloadedTemp = dir.appendingPathComponent("downloaded.tmp")
    XCTAssertTrue(FileManager.default.createFile(atPath: downloadedTemp.path,
                                                 contents: Data("audio-bytes".utf8)))

    coordinator.registerActiveDownload(
      sessionIdentifier: session, bookID: bookID, trackKey: "track-1",
      originalURL: url, localDestination: destination)

    // Sanity: registered and present before completion.
    XCTAssertEqual(coordinator.activeDownloads(forBookID: bookID).count, 1,
      "Precondition: the download is tracked before it completes")

    coordinator.handleBackgroundDownloadCompletion(
      sessionIdentifier: session, downloadedFileURL: downloadedTemp, originalURL: url)

    // Flush the coordinator's barrier queue with a sync read before asserting.
    let remaining = coordinator.activeDownloads(forBookID: bookID)

    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
      "The finalized file must be at its destination")
    XCTAssertTrue(remaining.isEmpty,
      "A finalized download must be pruned from activeDownloads, not left .completed")
    XCTAssertNil(coordinator.downloadInfo(forSessionIdentifier: session),
      "The session identifier must no longer resolve to a DownloadInfo after finalization")

    try? FileManager.default.removeItem(at: dir)
  }
}
