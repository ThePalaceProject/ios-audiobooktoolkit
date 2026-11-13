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

  func testFirstBuildWithoutASavedPositionStartsAtTheFirstTrack() throws {
    let player = try makePlayer(.anathem)
    let tracks = player.tableOfContents.allTracks

    player.lastKnownPosition = nil
    player.buildPlayerQueue()

    XCTAssertEqual(player.builtTrackKeys, tracks[0...4].map(\.key))
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

  // MARK: - Continuity at track ends

  /// Navigates the way AVQueuePlayer does once items are ready (advance, then
  /// land), and counts rebuilds, so a test can tell a queued next track from
  /// one that had to be rebuilt cold.
  final class ContinuityPlayer: OpenAccessPlayer {
    var rebuildCount = 0

    override func configurePlayer() {}
    override func addPlayerObservers() {}

    override func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
      tracks.map { track in
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null/\(track.index).mp3"))
        item.trackIdentifier = track.key
        return item
      }
    }

    override func rebuildPlayerQueueAndNavigate(
      to trackPosition: TrackPosition?,
      shouldResumePlayback: Bool = true,
      completion: ((Bool) -> Void)? = nil
    ) {
      rebuildCount += 1
      super.rebuildPlayerQueueAndNavigate(
        to: trackPosition, shouldResumePlayback: shouldResumePlayback, completion: completion
      )
    }

    override func navigateToItem(at index: Int, with timestamp: TimeInterval, completion: ((Bool) -> Void)? = nil) {
      for _ in 0..<index { avQueuePlayer.advanceToNextItem() }
      completion?(true)
    }
  }

  /// A book with one chapter per track finishes a chapter at every track end,
  /// and that path seeks rather than rebuilding. The queue must keep the next
  /// track loaded the whole way, not run dry after the first window.
  func testChapterEndsAcrossManyTracksNeverEmptyTheQueue() throws {
    let player = try makeContinuityPlayer(.bigFail)
    let tracks = player.tableOfContents.allTracks
    XCTAssertGreaterThanOrEqual(tracks.count, 14)

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[0], in: player))
    XCTAssertEqual(player.rebuildCount, 1)

    for index in 0..<13 {
      let ended = try XCTUnwrap(player.avQueuePlayer.currentItem)
      XCTAssertEqual(ended.trackIdentifier, tracks[index].key)

      endPlayback(of: ended)

      XCTAssertEqual(
        player.avQueuePlayer.currentItem?.trackIdentifier, tracks[index + 1].key,
        "Track \(index + 1) should follow track \(index)"
      )
      XCTAssertGreaterThanOrEqual(
        player.avQueuePlayer.items().count, 2,
        "The track after \(index + 1) should already be queued"
      )
      XCTAssertLessThanOrEqual(
        player.avQueuePlayer.items().count, 4,
        "The queue should hold a few tracks, not grow at every chapter end"
      )
      XCTAssertEqual(player.rebuildCount, 1, "Track \(index + 1) was rebuilt instead of already queued")
    }
  }

  func testTheLastQueuedTrackEndingPlaysTheNextTrackWithoutARebuild() throws {
    let player = try makeContinuityPlayer(.bigFail)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[10], in: player))
    while player.avQueuePlayer.items().count > 1 {
      player.avQueuePlayer.advanceToNextItem()
    }
    let last = try XCTUnwrap(player.avQueuePlayer.currentItem)
    XCTAssertEqual(last.trackIdentifier, tracks[14].key)

    endPlayback(of: last)

    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[15].key)
    XCTAssertEqual(
      player.avQueuePlayer.items().map(\.trackIdentifier), tracks[15...17].map(\.key),
      "Moving on to the next chapter should leave two tracks queued behind it"
    )
    XCTAssertEqual(player.rebuildCount, 1)
  }

  /// AVFoundation can advance to the next item before the end notice for the
  /// last one arrives. The top-up then counts from the item now playing.
  func testAnEndNoticeAfterTheAdvanceStillKeepsTheNextTrackQueued() throws {
    let player = try makeContinuityPlayer(.bigFail)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[10], in: player))
    while player.avQueuePlayer.items().count > 2 {
      player.avQueuePlayer.advanceToNextItem()
    }
    let ended = try XCTUnwrap(player.avQueuePlayer.currentItem)
    XCTAssertEqual(ended.trackIdentifier, tracks[13].key)
    player.avQueuePlayer.advanceToNextItem()

    endPlayback(of: ended)

    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[14].key)
    XCTAssertEqual(player.avQueuePlayer.items().map(\.trackIdentifier), tracks[14...16].map(\.key))
    XCTAssertEqual(player.rebuildCount, 1)
  }

  func testSeekingToThePreviousTrackAfterARebuildLandsThere() throws {
    let player = try makeContinuityPlayer(.bigFail)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[10], in: player))
    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[10].key)

    player.seekTo(position: position(tracks[9], in: player), completion: nil)

    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[9].key)
    XCTAssertEqual(
      player.avQueuePlayer.items().map(\.trackIdentifier),
      tracks[9...13].map(\.key),
      "The tracks after the previous one should be queued behind it"
    )
    XCTAssertEqual(player.rebuildCount, 2, "The previous track is not queued, so the skip back rebuilds once")
  }

  /// A jump to the last queued track advances through the queue rather than
  /// rebuilding, so it has to top the queue up as a chapter end does. Here
  /// that track then ends with AVFoundation advancing before the end notice.
  func testAJumpToTheLastQueuedTrackKeepsTheNextTrackQueued() throws {
    let player = try makeContinuityPlayer(.bigFail)
    let tracks = player.tableOfContents.allTracks

    player.rebuildPlayerQueueAndNavigate(to: position(tracks[10], in: player))
    player.seekTo(position: position(tracks[14], in: player), completion: nil)

    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[14].key)
    XCTAssertEqual(player.avQueuePlayer.items().map(\.trackIdentifier), tracks[14...16].map(\.key))

    let ended = try XCTUnwrap(player.avQueuePlayer.currentItem)
    player.avQueuePlayer.advanceToNextItem()
    endPlayback(of: ended)

    XCTAssertEqual(player.avQueuePlayer.currentItem?.trackIdentifier, tracks[15].key)
    XCTAssertGreaterThanOrEqual(player.avQueuePlayer.items().count, 2)
    XCTAssertEqual(player.rebuildCount, 1, "Track 15 was rebuilt instead of already queued")
  }

  /// Records where a chapter end sends playback instead of starting it, so
  /// the queue after the end handler shows only what the handler itself added.
  final class QuietLCPStreamingPlayer: LCPStreamingPlayer {
    var playRequests: [String] = []

    override func configurePlayer() {}
    override func addPlayerObservers() {}
    override func removePlayerObservers() {}

    override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
      playRequests.append(position.track.key)
    }
  }

  /// LCPStreamingPlayer hands a chapter end to the base handler through
  /// `super`, and the base handler tops the queue up. The streamed queue holds
  /// only the chapter being played, so nothing may be added there.
  func testLCPStreamingChapterEndDoesNotTopUpTheQueue() throws {
    let manifest = try Manifest.from(jsonFileName: ManifestJSON.bigFail.rawValue, bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: "queue-continuity-lcp", token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    let player = QuietLCPStreamingPlayer(tableOfContents: toc, drmDecryptor: nil)
    let playing = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null/3.mp3"))
    playing.trackIdentifier = toc.allTracks[3].key
    player.avQueuePlayer.insert(playing, after: nil)

    player.playerItemDidReachEnd(Notification(name: .AVPlayerItemDidPlayToEndTime, object: playing))

    XCTAssertEqual(player.playRequests, [toc.allTracks[4].key], "The chapter end should reach the base handler")
    XCTAssertEqual(player.avQueuePlayer.items().map(\.trackIdentifier), [toc.allTracks[3].key])
  }

  /// Delivers the end-of-item notification the way AVFoundation does, to the
  /// player's own observer for that item.
  private func endPlayback(of item: AVPlayerItem) {
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
  }

  private func makeContinuityPlayer(_ json: ManifestJSON) throws -> ContinuityPlayer {
    let manifest = try Manifest.from(jsonFileName: json.rawValue, bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: "queue-continuity-\(json.rawValue)", token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    XCTAssertEqual(toc.toc.count, tracks.count, "Needs one chapter per track")
    return ContinuityPlayer(tableOfContents: toc)
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
