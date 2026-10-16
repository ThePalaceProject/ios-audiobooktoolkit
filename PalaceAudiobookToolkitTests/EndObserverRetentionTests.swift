//
//  EndObserverRetentionTests.swift
//  PalaceAudiobookToolkitTests
//
//  End-of-item notifications are registered per AVPlayerItem, and the handler
//  reads the item off the notification rather than off the queue. A
//  registration that outlives the item it was made for can therefore move the
//  player for a chapter that is not playing, so the two places a queue is
//  discarded are pinned here.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import XCTest
@testable import PalaceAudiobookToolkit

/// A silent local file, so an AVPlayerItem can be built and queued without a
/// network or a resource loader.
enum SilentAudioFixture {
  static let url: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("silent-\(UUID().uuidString).wav")
    // A 44-byte WAV header describing zero samples.
    var wav = Data("RIFF".utf8)
    wav.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
    wav.append(Data("WAVEfmt ".utf8))
    wav.append(contentsOf: [0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
    wav.append(contentsOf: [0x44, 0xAC, 0x00, 0x00, 0x88, 0x58, 0x01, 0x00])
    wav.append(contentsOf: [0x02, 0x00, 0x10, 0x00])
    wav.append(Data("data".utf8))
    wav.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    try? wav.write(to: url)
    return url
  }()
}

@MainActor
final class EndObserverRetentionTests: XCTestCase {

  // MARK: - Test doubles

  /// Skips the audio session and the initial queue build so the queue under
  /// test is only what each test puts in it. The end-observer registration and
  /// removal are the real ones.
  private final class TestOpenAccessPlayer: OpenAccessPlayer {
    override func configurePlayer() {}
    override func addPlayerObservers() {}
  }

  /// Records which chapter the player was told to play, which is the handler's
  /// observable effect on the LCP path. `super` still runs, so the queue work
  /// the recording wraps is the production one.
  private final class RecordingLCPStreamingPlayer: LCPStreamingPlayer {
    var navigatedTrackKeys: [String] = []
    override func configurePlayer() {}
    override func addPlayerObservers() {}
    override func removePlayerObservers() {}
    override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
      navigatedTrackKeys.append(position.track.key)
      super.playCallback(at: position, completion: completion)
    }
  }

  // MARK: - Fixture

  private var toc: AudiobookTableOfContents!
  private var tracks: [any Track]!

  override func setUp() async throws {
    try await super.setUp()
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "end-observer-test", decryptor: nil, token: nil),
      "Fixture manifest failed to parse"
    )
    toc = audiobook.tableOfContents
    tracks = toc.allTracks
  }

  /// A track with a predecessor and a successor, so the handler has somewhere
  /// wrong to go.
  private func middleTrack() throws -> any Track {
    try XCTUnwrap(tracks.dropFirst(3).first, "Fixture must carry at least five tracks")
  }

  private func item(for track: any Track) -> AVPlayerItem {
    let item = AVPlayerItem(url: SilentAudioFixture.url)
    item.trackIdentifier = track.key
    return item
  }

  // MARK: - unload

  /// `unload` dropped the queue without unregistering its end observers, so an
  /// item it discarded could still reach the handler. The handler navigates to
  /// the track after the one named by the notification, and that navigation
  /// rewrites `lastKnownPosition` — the value the host saves and syncs. A
  /// player with nothing loaded must keep the position it was unloaded at.
  func testUnload_thenAnEndNotificationForADiscardedItem_leavesTheSavedPositionAlone() throws {
    let player = TestOpenAccessPlayer(tableOfContents: toc)
    let discarded = item(for: try middleTrack())
    player.avQueuePlayer.insert(discarded, after: nil)
    player.addEndObserver(for: discarded)
    let restingTrack = try XCTUnwrap(tracks.first)
    player.lastKnownPosition = TrackPosition(track: restingTrack, timestamp: 42, tracks: toc.tracks)

    player.unload()
    // `discarded` is still referenced here, which is the condition a
    // registration outliving its item depends on.
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: discarded)

    XCTAssertEqual(
      player.lastKnownPosition?.track.key, restingTrack.key,
      "an unloaded player must not be navigated by an item it discarded"
    )
    XCTAssertEqual(player.lastKnownPosition?.timestamp, 42, "the saved timestamp must survive unload")
    XCTAssertTrue(player.avQueuePlayer.items().isEmpty, "an unloaded player holds nothing to play")
  }

  // MARK: - Queue rebuild

  /// The LCP rebuild inside `playCallback` dropped the queue without
  /// unregistering its end observers. Every chapter change and every seek that
  /// rebuilds leaves one behind, and the preloaded following chapter means a
  /// rebuild can discard two observed items rather than one.
  func testQueueRebuild_thenAnEndNotificationForADiscardedItem_doesNotNavigateAgain() throws {
    let player = RecordingLCPStreamingPlayer(tableOfContents: toc, drmDecryptor: nil)
    let discarded = item(for: try middleTrack())
    player.avQueuePlayer.insert(discarded, after: nil)
    player.addEndObserver(for: discarded)
    let targetTrack = try XCTUnwrap(tracks.first)
    let target = TrackPosition(track: targetTrack, timestamp: 0, tracks: toc.tracks)

    player.playCallback(at: target, completion: nil)
    XCTAssertFalse(
      player.avQueuePlayer.items().contains(discarded),
      "Precondition: the rebuild must have discarded the item"
    )
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: discarded)

    XCTAssertEqual(
      player.navigatedTrackKeys, [targetTrack.key],
      "an item the rebuild discarded must not send the player to the chapter after it"
    )
  }

  /// The converse, so the fix cannot be "stop handling the notification": an
  /// item the player still holds must still carry the book into the next track.
  func testEndNotification_forAnItemStillQueued_stillNavigates() throws {
    let player = RecordingLCPStreamingPlayer(tableOfContents: toc, drmDecryptor: nil)
    let playing = item(for: try middleTrack())
    player.avQueuePlayer.insert(playing, after: nil)
    player.addEndObserver(for: playing)
    let following = try XCTUnwrap(tracks.dropFirst(4).first, "Fixture must carry a track after the middle one")

    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playing)

    XCTAssertEqual(
      player.navigatedTrackKeys, [following.key],
      "a queued item reaching its end must still advance the book"
    )
  }
}
