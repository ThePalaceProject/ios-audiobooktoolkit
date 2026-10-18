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

  /// The gate must be the remoteness of the archive, not the presence of
  /// streaming: once the archive is on disk, prefetching reads no link at all.
  func test_openingABookWhoseArchiveIsLocal_stillPrefetches() throws {
    let (model, spy) = try makeModel(id: "pp5367-local", servingRemoteArchive: false)
    withExtendedLifetime(model) {
      XCTAssertEqual(
        spy.fetchCallCount, 1,
        "a local archive costs no egress, so the prefetch must still run"
      )
    }
  }

  /// Every non-streaming format reaches the same initializer, so the gate must
  /// leave a player that knows nothing about archives alone.
  func test_openingANonStreamingBook_stillPrefetches() throws {
    let (model, spy) = try makeModel(id: "pp5367-plain", servingRemoteArchive: nil)
    withExtendedLifetime(model) {
      XCTAssertEqual(
        spy.fetchCallCount, 1,
        "a player with no streaming session must keep the prefetch it has always had"
      )
    }
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
