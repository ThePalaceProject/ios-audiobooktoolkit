//
//  AudiobookPrefetchGateTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-5367 — whole-track prefetch must not race the chapter being streamed.
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

/// Opening a streaming LCP audiobook used to start the whole-track prefetch
/// unconditionally. Each prefetched track is read and decrypted in full from
/// the remote archive, three at a time, across the same link the chapter the
/// patron is waiting on has to cross.
@MainActor
final class AudiobookPrefetchGateTests: XCTestCase {

  private func makeAudiobook(id: String) throws -> OpenAccessAudiobook {
    let manifest = try Manifest.from(
      jsonFileName: "alice_manifest",
      bundle: Bundle(for: type(of: self))
    )
    return try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: id, decryptor: nil, token: nil)
    )
  }

  private func makeModel(
    id: String,
    servingRemoteArchive: Bool?
  ) throws -> (AudiobookPlaybackModel, NetworkServiceSpy) {
    let audiobook = try makeAudiobook(id: id)
    if let servingRemoteArchive {
      let player = StreamingPlayerMock(tableOfContents: audiobook.tableOfContents)
      player.isLoaded = false
      player.servingRemoteArchive = servingRemoteArchive
      audiobook.player = player
    } else {
      let player = PlayerMock(tableOfContents: audiobook.tableOfContents)
      player.isLoaded = false
      audiobook.player = player
    }
    let spy = NetworkServiceSpy(tracks: audiobook.tableOfContents.allTracks)
    let manager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Prefetch Gate", authors: ["A"]),
      audiobook: audiobook,
      networkService: spy
    )
    return (AudiobookPlaybackModel(audiobookManager: manager), spy)
  }

  /// The defect: the prefetch of whole tracks is started while every byte of
  /// them has to come over the link the chapter is already using.
  func test_openingAStreamingBook_doesNotPrefetchWholeTracks() throws {
    let (model, spy) = try makeModel(id: "pp5367-remote", servingRemoteArchive: true)
    withExtendedLifetime(model) {
      XCTAssertEqual(
        spy.fetchCallCount, 0,
        "a book served from a remote archive must not prefetch whole tracks over the same link"
      )
    }
  }

  /// Deferred for every vendor, not only LCP: three full-track transfers at
  /// open cross the same link the first chapter needs whatever the format.
  func test_openingABookWhoseArchiveIsLocal_doesNotPrefetchYet() throws {
    let (model, spy) = try makeModel(id: "pp5367-local", servingRemoteArchive: false)
    withExtendedLifetime(model) {
      XCTAssertEqual(spy.fetchCallCount, 0, "the prefetch must not start while the first chapter loads")
    }
  }

  func test_openingANonStreamingBook_doesNotPrefetchYet() throws {
    let (model, spy) = try makeModel(id: "pp5367-plain", servingRemoteArchive: nil)
    withExtendedLifetime(model) {
      XCTAssertEqual(spy.fetchCallCount, 0, "a player with no streaming session is deferred too")
    }
  }

  // MARK: - When the deferred prefetch becomes due

  private func due(
    isPlaying: Bool = false,
    seconds: TimeInterval = 0,
    started: Bool = false,
    remote: Bool = false
  ) -> Bool {
    AudiobookPlaybackModel.shouldStartDeferredPrefetch(
      isPlaying: isPlaying, secondsSinceOpen: seconds,
      alreadyStarted: started, servingRemoteArchive: remote
    )
  }

  func test_atOpen_theBookIsNotYetDue() {
    XCTAssertFalse(due())
  }

  /// Playback starting means the chapter has the bytes it needed.
  func test_oncePlaybackStarts_itIsDueImmediately() {
    XCTAssertTrue(due(isPlaying: true))
  }

  /// The bound that stops this becoming a deadlock: a vendor whose player needs
  /// tracks on disk never reports playing, and must still get its download.
  func test_pastTheGraceWindow_itIsDueEvenWithoutPlayback() {
    XCTAssertTrue(due(seconds: AudiobookPlaybackModel.deferredPrefetchGrace))
    XCTAssertFalse(
      due(seconds: AudiobookPlaybackModel.deferredPrefetchGrace - 0.01),
      "the bound must not fire early"
    )
  }

  /// The poll fires twice a second for the whole session; the prefetch is one
  /// transfer set, not one per tick.
  func test_onceStarted_itIsNeverDueAgain() {
    XCTAssertFalse(due(isPlaying: true, seconds: 600, started: true))
  }

  /// A remote LCP archive is served by byte ranges and fetched whole separately,
  /// so its prefetch is skipped outright rather than deferred.
  func test_aRemoteLCPArchive_isNeverDue() {
    XCTAssertFalse(due(isPlaying: true, seconds: 600, remote: true))
  }
}

// MARK: - Doubles

private final class NetworkServiceSpy: AudiobookNetworkService {
  let tracks: [any Track]
  let downloadStatePublisher = PassthroughSubject<DownloadState, Never>()
  private(set) var fetchCallCount = 0

  init(tracks: [any Track]) {
    self.tracks = tracks
  }

  func fetch() { fetchCallCount += 1 }
  func fetchUndownloadedTracks() {}
  func deleteAll() {}
  func cleanup() {}
}

private final class StreamingPlayerMock: PlayerMock, StreamingCapablePlayer {
  var servingRemoteArchive = true

  var isServingRemoteArchive: Bool { servingRemoteArchive }

  func publicationDidLoad() {}
  func setStreamingProvider(_ provider: StreamingResourceProvider) {}
}
