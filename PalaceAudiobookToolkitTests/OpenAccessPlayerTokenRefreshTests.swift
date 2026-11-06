//
//  OpenAccessPlayerTokenRefreshTests.swift
//  PalaceAudiobookToolkitTests
//
//  The streaming bearer-token refresh clears `isRefreshingToken` on the main
//  queue (PP-5496). These tests pin that the flag clears on both outcomes and
//  that a later refresh can start.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

/// Serves the fulfill response. The refresh uses `URLSession.shared`, which is
/// not injectable, so the seam is a registered `URLProtocol`.
private final class RefreshStubProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var _statusCode = 200
  private static var _body = Data()
  private static var _requestCount = 0

  static func configure(statusCode: Int, body: Data) {
    lock.lock(); defer { lock.unlock() }
    _statusCode = statusCode; _body = body; _requestCount = 0
  }

  static var requestCount: Int {
    lock.lock(); defer { lock.unlock() }
    return _requestCount
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "refresh.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self._requestCount += 1
    let statusCode = Self._statusCode
    let body = Self._body
    Self.lock.unlock()

    let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
final class OpenAccessPlayerTokenRefreshTests: XCTestCase {

  /// Records the flag when the success path's main-queue work runs, and keeps
  /// the real queue rebuild (which would load remote audio) out of the test.
  final class RefreshRecordingPlayer: OpenAccessPlayer {
    var flagDuringRebuild: [Bool] = []
    var onRebuild: (() -> Void)?

    override func configurePlayer() {}
    override func addPlayerObservers() {}

    override func rebuildPlayerQueueAndNavigate(
      to trackPosition: TrackPosition?,
      shouldResumePlayback: Bool = true,
      completion: ((Bool) -> Void)? = nil
    ) {
      flagDuringRebuild.append(isRefreshingToken)
      onRebuild?()
    }
  }

  private var cancellables = Set<AnyCancellable>()

  override func setUp() {
    super.setUp()
    URLProtocol.registerClass(RefreshStubProtocol.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(RefreshStubProtocol.self)
    cancellables.removeAll()
    super.tearDown()
  }

  private func makePlayer() throws -> RefreshRecordingPlayer {
    let manifest = try Manifest.from(jsonFileName: "alice_manifest", bundle: Bundle(for: type(of: self)))
    let audiobook = try XCTUnwrap(
      OpenAccessAudiobook(manifest: manifest, bookIdentifier: "token-refresh-test", decryptor: nil, token: "old"),
      "Fixture manifest failed to parse"
    )
    audiobook.tableOfContents.tracks.fulfillURL = URL(string: "https://refresh.test/fulfill")!
    return RefreshRecordingPlayer(tableOfContents: audiobook.tableOfContents)
  }

  /// Lets every block already queued on the main queue run first.
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  private func refreshAndAwaitRebuild(_ player: RefreshRecordingPlayer) async {
    let rebuilt = expectation(description: "queue rebuilt")
    player.onRebuild = { rebuilt.fulfill() }
    player.refreshBearerTokenAndRebuildQueue()
    await fulfillment(of: [rebuilt], timeout: 10)
    player.onRebuild = nil
  }

  private func refreshAndAwaitFailure(_ player: RefreshRecordingPlayer) async -> Bool? {
    let failed = expectation(description: "failure published")
    var flagAtFailure: Bool?
    player.playbackStatePublisher
      .sink { [weak player] state in
        guard case .failed = state, flagAtFailure == nil else { return }
        flagAtFailure = player?.isRefreshingToken
        failed.fulfill()
      }
      .store(in: &cancellables)
    player.refreshBearerTokenAndRebuildQueue()
    await fulfillment(of: [failed], timeout: 10)
    cancellables.removeAll()
    return flagAtFailure
  }

  /// On success the flag clears on the main queue, after the queued rebuild,
  /// and a second refresh sends a second request.
  func testRefresh_whenFulfillSucceeds_clearsFlagOnMainQueueAndAllowsAnotherRefresh() async throws {
    RefreshStubProtocol.configure(statusCode: 200, body: Data(#"{"access_token":"new-token"}"#.utf8))
    let player = try makePlayer()

    await refreshAndAwaitRebuild(player)
    XCTAssertEqual(player.flagDuringRebuild, [true], "The flag must clear on the main queue after the rebuild it queues")
    await drainMainQueue()
    XCTAssertFalse(player.isRefreshingToken)

    await refreshAndAwaitRebuild(player)
    XCTAssertEqual(RefreshStubProtocol.requestCount, 2, "A second refresh must start once the first completes")
  }

  /// On failure the flag clears on the main queue, after the queued error,
  /// and a second refresh sends a second request.
  func testRefresh_whenFulfillFails_clearsFlagOnMainQueueAndAllowsAnotherRefresh() async throws {
    RefreshStubProtocol.configure(statusCode: 500, body: Data())
    let player = try makePlayer()

    let flagAtFailure = await refreshAndAwaitFailure(player)
    XCTAssertEqual(flagAtFailure, true, "The flag must clear on the main queue after the error it queues")
    await drainMainQueue()
    XCTAssertFalse(player.isRefreshingToken)

    _ = await refreshAndAwaitFailure(player)
    XCTAssertEqual(RefreshStubProtocol.requestCount, 2, "A second refresh must start once the first fails")
  }

  /// A refresh requested while one is in flight sends no second request.
  func testRefresh_whileRefreshInFlight_sendsOneRequest() async throws {
    RefreshStubProtocol.configure(statusCode: 200, body: Data(#"{"access_token":"new-token"}"#.utf8))
    let player = try makePlayer()

    let rebuilt = expectation(description: "queue rebuilt")
    player.onRebuild = { rebuilt.fulfill() }
    player.refreshBearerTokenAndRebuildQueue()
    player.refreshBearerTokenAndRebuildQueue()
    await fulfillment(of: [rebuilt], timeout: 10)
    await drainMainQueue()

    XCTAssertEqual(RefreshStubProtocol.requestCount, 1)
    XCTAssertFalse(player.isRefreshingToken)
  }
}
