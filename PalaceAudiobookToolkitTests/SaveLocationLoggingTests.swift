//
//  SaveLocationLoggingTests.swift
//  PalaceAudiobookToolkitTests
//
//  `saveLocation` hands the position to the bookmark delegate. A nil server ID
//  from the delegate is the normal result of a throttled or queued write, so it
//  must not be logged as an error: the host persists error-level lines to the
//  log patrons export, and a line per throttle window hides real failures.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class SaveLocationLoggingTests: XCTestCase {
  private final class StubBookmarkDelegate: AudiobookBookmarkDelegate {
    var serverID: String?
    private(set) var savedPositions: [TrackPosition] = []
    func saveListeningPosition(at location: TrackPosition, completion: ((String?) -> Void)?) {
      savedPositions.append(location)
      completion?(serverID)
    }
    func saveBookmark(at location: TrackPosition, completion: ((TrackPosition?) -> Void)?) { completion?(nil) }
    func deleteBookmark(at location: TrackPosition, completion: ((Bool) -> Void)?) { completion?(false) }
    func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void) { completion([]) }
    func flushPendingOperations() {}
    func saveListeningPositionSync(at position: TrackPosition) {}
  }

  private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _errors: [String] = []
    var errors: [String] { lock.withLock { _errors } }
    func record(_ level: LogLevel, _ message: String) {
      guard level == .error else { return }
      lock.withLock { _errors.append(message) }
    }
  }

  private var previousLogHandler: LogHandler?

  override func setUp() {
    super.setUp()
    previousLogHandler = sharedLogHandler
  }

  override func tearDown() {
    sharedLogHandler = previousLogHandler
    super.tearDown()
  }

  private func makeManager() throws -> (DefaultAudiobookManager, StubBookmarkDelegate, TrackPosition) {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "save-location-logging", decryptor: nil, token: nil)
    )
    let player = PlayerMock(tableOfContents: audiobook.tableOfContents)
    player.isPlaying = false
    audiobook.player = player
    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Save Location", authors: ["A"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks)
    )
    let delegate = StubBookmarkDelegate()
    manager.bookmarkDelegate = delegate
    let track = try XCTUnwrap(audiobook.tableOfContents.allTracks.first)
    let position = TrackPosition(track: track, timestamp: 42, tracks: audiobook.tableOfContents.tracks)
    return (manager, delegate, position)
  }

  /// The host returns nil for every save inside its throttle window; logging that
  /// at error wrote one persisted ERROR line per window during normal playback.
  func testSaveLocation_whenDelegateReturnsNoServerID_logsNoError() throws {
    let (manager, delegate, position) = try makeManager()
    delegate.serverID = nil
    let capture = LogCapture()
    sharedLogHandler = { level, message, _ in capture.record(level, message) }

    manager.saveLocation(position)

    XCTAssertEqual(delegate.savedPositions.count, 1, "The position must still reach the delegate")
    XCTAssertEqual(capture.errors.filter { $0.contains("AudiobookManager.swift") }, [],
                   "A throttled or queued save is not an error")
  }

  /// The position the manager is given is the one the delegate persists.
  func testSaveLocation_forwardsThePositionToTheDelegate() throws {
    let (manager, delegate, position) = try makeManager()
    delegate.serverID = "server-id"

    manager.saveLocation(position)

    XCTAssertEqual(delegate.savedPositions.count, 1)
    XCTAssertEqual(delegate.savedPositions.first?.timestamp ?? -1, 42, accuracy: 0.001)
    XCTAssertEqual(delegate.savedPositions.first?.track.key, position.track.key)
  }
}
