//
//  OpenAccessQueueWindowTests.swift
//  PalaceAudiobookToolkitTests
//
//  A queue rebuild enqueues the same few tracks as the first build: the track
//  before the target and the four after it. Overdrive books keep every track
//  queued, as they always have (PP-5586).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AVFoundation
import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class OpenAccessQueueWindowTests: XCTestCase {

  /// Records which tracks the queue is built from and which queue index it
  /// navigates to, without loading audio or touching the audio session.
  final class WindowRecordingPlayer: OpenAccessPlayer {
    var builtTrackKeys: [String] = []
    var navigatedIndex: Int?

    override func configurePlayer() {}
    override func addPlayerObservers() {}

    override func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
      builtTrackKeys = tracks.map(\.key)
      return tracks.map { track in
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null/\(track.index).mp3"))
        item.trackIdentifier = track.key
        return item
      }
    }

    override func navigateToItem(at index: Int, with timestamp: TimeInterval, completion: ((Bool) -> Void)? = nil) {
      navigatedIndex = index
      completion?(true)
    }
  }

  // MARK: - Open access

  func testRebuildEnqueuesTheTrackBeforeAndFourAfterTheTarget() throws {
    let player = try makePlayer(.anathem)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[30], in: player))

    XCTAssertEqual(player.builtTrackKeys, tracks[29...34].map(\.key))
    XCTAssertEqual(player.avQueuePlayer.items().map(\.trackIdentifier), tracks[29...34].map(\.key))
    XCTAssertEqual(player.navigatedIndex, 1, "The target is the second item, after the track before it")
  }

  func testRebuildAtTheLastTrackStopsAtTheEndOfTheBook() throws {
    let player = try makePlayer(.anathem)
    let tracks = player.tableOfContents.allTracks
    let last = tracks.count - 1

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[last], in: player))

    XCTAssertEqual(player.builtTrackKeys, tracks[(last - 1)...last].map(\.key))
    XCTAssertEqual(player.navigatedIndex, 1)
  }

  func testRebuildAtTheFirstTrackStartsAtTheBeginningOfTheBook() throws {
    let player = try makePlayer(.anathem)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[0], in: player))

    XCTAssertEqual(player.builtTrackKeys, tracks[0...4].map(\.key))
    XCTAssertEqual(player.navigatedIndex, 0)
  }

  /// Without a target the rebuild has always landed on the book's first track.
  func testRebuildWithoutATargetLandsOnTheFirstTrack() throws {
    let player = try makePlayer(.anathem)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: nil)

    XCTAssertEqual(player.builtTrackKeys, tracks[0...4].map(\.key))
    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[0].key)
    XCTAssertEqual(player.navigatedIndex, 0)
  }

  func testRebuildUsesTheSameWindowAsTheFirstBuild() throws {
    let player = try makePlayer(.anathem)
    let tracks = player.tableOfContents.allTracks
    let target = position(tracks[30], in: player)

    player.lastKnownPosition = target
    player.buildPlayerQueue()
    let firstBuild = player.builtTrackKeys

    player.rebuildPlayerQueueAndNavigate(to: target)

    XCTAssertEqual(player.builtTrackKeys, firstBuild)
  }

  // MARK: - Overdrive

  func testOverdriveRebuildStillQueuesEveryTrack() throws {
    let player = try makeOverdrivePlayer(trackCount: 10)
    let tracks = player.tableOfContents.allTracks
    XCTAssertEqual(tracks.count, 10)

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[6], in: player))

    XCTAssertEqual(player.builtTrackKeys, tracks.map(\.key))
    XCTAssertEqual(player.navigatedIndex, 6)
  }

  func testOverdriveFirstBuildStillQueuesEveryTrack() throws {
    let player = try makeOverdrivePlayer(trackCount: 10)
    let tracks = player.tableOfContents.allTracks

    player.lastKnownPosition = position(tracks[6], in: player)
    player.buildPlayerQueue()

    XCTAssertEqual(player.builtTrackKeys, tracks.map(\.key))
  }

  // MARK: - Window bounds

  func testWindowForABookWithNoTracksIsEmpty() {
    XCTAssertNil(OpenAccessPlayer.queueTrackRange(around: 0, trackCount: 0, wholeBook: false))
    XCTAssertNil(OpenAccessPlayer.queueTrackRange(around: 0, trackCount: 0, wholeBook: true))
  }

  func testWindowForAnIndexPastTheEndEndsAtTheLastTrack() {
    XCTAssertEqual(OpenAccessPlayer.queueTrackRange(around: 99, trackCount: 10, wholeBook: false), 8...9)
  }

  func testWindowForANegativeIndexStartsAtTheFirstTrack() {
    XCTAssertEqual(OpenAccessPlayer.queueTrackRange(around: -3, trackCount: 10, wholeBook: false), 0...4)
  }

  func testWindowForAOneTrackBookIsThatTrack() {
    XCTAssertEqual(OpenAccessPlayer.queueTrackRange(around: 0, trackCount: 1, wholeBook: false), 0...0)
  }

  // MARK: - Helpers

  private func position(_ track: any Track, in player: OpenAccessPlayer) -> TrackPosition {
    TrackPosition(track: track, timestamp: 0, tracks: player.tableOfContents.tracks)
  }

  private func makePlayer(_ json: ManifestJSON) throws -> WindowRecordingPlayer {
    let manifest = try Manifest.from(jsonFileName: json.rawValue, bundle: Bundle(for: type(of: self)))
    return makePlayer(manifest: manifest, id: "queue-window-\(json.rawValue)")
  }

  /// The Overdrive fixture has three parts, fewer than one window, so its
  /// content links are repeated to make a book long enough to tell the whole
  /// book from a window.
  private func makeOverdrivePlayer(trackCount: Int) throws -> WindowRecordingPlayer {
    let url = try XCTUnwrap(Bundle(for: type(of: self)).url(
      forResource: ManifestJSON.animalFarm.rawValue, withExtension: "json"
    ))
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    var links = try XCTUnwrap(json["links"] as? [String: Any])
    let template = try XCTUnwrap((links["contentlinks"] as? [[String: Any]])?.first)
    links["contentlinks"] = (0..<trackCount).map { index -> [String: Any] in
      var link = template
      link["href"] = "\(template["href"] as? String ?? "")&part=\(index)"
      return link
    }
    json["links"] = links

    let manifest = try Manifest.customDecoder().decode(
      Manifest.self, from: JSONSerialization.data(withJSONObject: json)
    )
    XCTAssertEqual(manifest.audiobookType, .overdrive)
    return makePlayer(manifest: manifest, id: "queue-window-overdrive")
  }

  private func makePlayer(manifest: Manifest, id: String) -> WindowRecordingPlayer {
    let tracks = Tracks(manifest: manifest, audiobookID: id, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    return WindowRecordingPlayer(tableOfContents: toc)
  }
}
