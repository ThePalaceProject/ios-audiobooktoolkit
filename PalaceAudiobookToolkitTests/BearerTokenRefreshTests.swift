//
//  BearerTokenRefreshTests.swift
//  PalaceAudiobookToolkitTests
//
//  Tests for PP-3702: Bearer token refresh on expiration.
//  Covers fulfillURL propagation, token refresh attempt logic,
//  and retry guard behavior in OpenAccessDownloadTask.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import PalaceAudiobookToolkit

// MARK: - Tracks.fulfillURL Propagation Tests

final class TracksFulfillURLTests: XCTestCase {

    /// Verifies that setting fulfillURL on Tracks propagates to all OpenAccessDownloadTask instances.
    func testSetFulfillURL_propagatesToAllDownloadTasks() {
        let manifest = Manifest.mockManifest
        let tracks = Tracks(manifest: manifest, audiobookID: "test-book", token: "initial-token")

        let fulfillURL = URL(string: "https://cm.example.com/fulfill/book-123")!
        tracks.fulfillURL = fulfillURL

        for track in tracks.tracks {
            if let oaTask = track.downloadTask as? OpenAccessDownloadTask {
                XCTAssertEqual(
                    oaTask.fulfillURL, fulfillURL,
                    "Track \(track.key) should have fulfillURL propagated"
                )
            }
        }
    }

    /// Verifies that fulfillURL defaults to nil.
    func testFulfillURL_defaultsToNil() {
        let manifest = Manifest.mockManifest
        let tracks = Tracks(manifest: manifest, audiobookID: "test-book", token: nil)

        XCTAssertNil(tracks.fulfillURL)
    }

    /// Verifies that updating fulfillURL overwrites the previous value on all tasks.
    func testSetFulfillURL_overwritesPreviousValue() {
        let manifest = Manifest.mockManifest
        let tracks = Tracks(manifest: manifest, audiobookID: "test-book", token: "tok")

        let url1 = URL(string: "https://cm.example.com/fulfill/v1")!
        let url2 = URL(string: "https://cm.example.com/fulfill/v2")!

        tracks.fulfillURL = url1
        tracks.fulfillURL = url2

        for track in tracks.tracks {
            if let oaTask = track.downloadTask as? OpenAccessDownloadTask {
                XCTAssertEqual(oaTask.fulfillURL, url2)
            }
        }
    }

    /// Verifies that setting token updates the Tracks token property.
    func testSetToken_updatesTracksToken() {
        let manifest = Manifest.mockManifest
        let tracks = Tracks(manifest: manifest, audiobookID: "test-book", token: "old-token")

        tracks.token = "new-token"

        XCTAssertEqual(tracks.token, "new-token")
    }
}

// MARK: - OpenAccessDownloadTask Token Refresh Tests

final class OpenAccessDownloadTaskTokenRefreshTests: XCTestCase {

    private func makeTask(
        token: String? = "test-token",
        fulfillURL: URL? = nil
    ) -> OpenAccessDownloadTask {
        let task = OpenAccessDownloadTask(
            key: "test-track-\(UUID().uuidString.prefix(8))",
            downloadURL: URL(string: "https://distributor.example.com/content/chapter1.mp3")!,
            urlString: "https://distributor.example.com/content/chapter1.mp3",
            urlMediaType: .audioMPEG,
            alternateLinks: nil,
            feedbooksProfile: nil,
            token: token
        )
        task.fulfillURL = fulfillURL
        return task
    }

    // MARK: - attemptTokenRefreshAndRetry

    func testAttemptRefresh_withNoFulfillURL_returnsFalse() {
        let task = makeTask(fulfillURL: nil)

        let result = task.attemptTokenRefreshAndRetry()

        XCTAssertFalse(result, "Should not attempt refresh without a fulfill URL")
    }

    func testAttemptRefresh_withFulfillURL_returnsTrue() {
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/123")!
        let task = makeTask(fulfillURL: fulfillURL)

        let result = task.attemptTokenRefreshAndRetry()

        XCTAssertTrue(result, "Should attempt refresh when fulfill URL is available")
    }

    func testAttemptRefresh_secondAttempt_returnsFalse() {
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/123")!
        let task = makeTask(fulfillURL: fulfillURL)

        let firstAttempt = task.attemptTokenRefreshAndRetry()
        XCTAssertTrue(firstAttempt)

        let secondAttempt = task.attemptTokenRefreshAndRetry()
        XCTAssertFalse(secondAttempt, "Should not attempt refresh twice without a successful refresh in between")
    }

    // MARK: - fulfillURL Property

    func testFulfillURL_defaultsToNil() {
        let task = makeTask()
        XCTAssertNil(task.fulfillURL)
    }

    func testFulfillURL_canBeSet() {
        let task = makeTask()
        let url = URL(string: "https://cm.example.com/fulfill/abc")!

        task.fulfillURL = url

        XCTAssertEqual(task.fulfillURL, url)
    }

    // MARK: - Token Property

    func testToken_canBeUpdated() {
        let task = makeTask(token: "old-token")

        task.token = "refreshed-token"

        XCTAssertEqual(task.token, "refreshed-token")
    }

    func testToken_nilByDefault_whenNotProvided() {
        let task = makeTask(token: nil)

        XCTAssertNil(task.token)
    }

    // MARK: - Error State on Failed Refresh

    func testAttemptRefresh_failure_publishesAuthError() {
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/will-fail")!
        let task = makeTask(fulfillURL: fulfillURL)

        var receivedError: NSError?
        let expectation = expectation(description: "Error published after failed refresh")

        let cancellable = task.statePublisher.sink { state in
            if case .error(let error) = state {
                receivedError = error as? NSError
                expectation.fulfill()
            }
        }

        _ = task.attemptTokenRefreshAndRetry()

        waitForExpectations(timeout: 10)
        cancellable.cancel()

        XCTAssertNotNil(receivedError)
        XCTAssertEqual(receivedError?.domain, OpenAccessPlayerErrorDomain)
        XCTAssertEqual(receivedError?.code, OpenAccessPlayerError.authenticationRequired.rawValue)
    }
}

// MARK: - Audiobook.setFulfillURL Integration Test

final class AudiobookFulfillURLTests: XCTestCase {

    func testAudiobookFactory_passesFulfillURL() {
        let manifest = Manifest.mockManifest
        let fulfillURL = URL(string: "https://cm.example.com/fulfill/integration")!

        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: "integration-test",
            decryptor: nil,
            token: "test-token",
            fulfillURL: fulfillURL
        )

        XCTAssertNotNil(audiobook)
        XCTAssertEqual(
            audiobook?.tableOfContents.tracks.fulfillURL,
            fulfillURL,
            "AudiobookFactory should propagate fulfillURL to tracks"
        )
    }

    func testAudiobookFactory_nilFulfillURL_doesNotSet() {
        let manifest = Manifest.mockManifest

        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: "no-fulfill-test",
            decryptor: nil,
            token: "test-token",
            fulfillURL: nil
        )

        XCTAssertNotNil(audiobook)
        XCTAssertNil(audiobook?.tableOfContents.tracks.fulfillURL)
    }

    func testSetFulfillURL_propagatesThroughTableOfContents() {
        let manifest = Manifest.mockManifest

        let audiobook = AudiobookFactory.audiobook(
            for: manifest,
            bookIdentifier: "propagation-test",
            decryptor: nil,
            token: "test-token"
        )

        XCTAssertNotNil(audiobook)

        let url = URL(string: "https://cm.example.com/fulfill/late-set")!
        audiobook?.setFulfillURL(url)

        XCTAssertEqual(audiobook?.tableOfContents.tracks.fulfillURL, url)

        for track in audiobook?.tableOfContents.tracks.tracks ?? [] {
            if let oaTask = track.downloadTask as? OpenAccessDownloadTask {
                XCTAssertEqual(oaTask.fulfillURL, url,
                    "setFulfillURL should propagate to individual download tasks")
            }
        }
    }
}
