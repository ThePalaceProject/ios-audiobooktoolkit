//
//  AudiobookPlaybackModelTests.swift
//  PalaceAudiobookToolkitTests
//
//  Regression coverage for PP-4156 — download indicator visibility.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class AudiobookPlaybackModelTests: XCTestCase {
  // MARK: - PP-4156 — download-indicator visibility rule
  //
  // The download indicator must be visible whenever overall download progress is
  // less than 1.0, regardless of player type. A prior commit branched on
  // `audiobookManager.audiobook.player is LCPStreamingPlayer` and forced
  // `isDownloading = false` for LCP titles, which silently hid the indicator
  // while LCP tracks were decrypting in the background.
  //
  // The rule lives on AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress:),
  // a static function whose signature accepts only progress. Re-introducing player-type
  // branching would require changing the signature, which would fail this build.

  func test_shouldShowDownloadIndicator_isVisibleAtZeroProgress() {
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.0))
  }

  func test_shouldShowDownloadIndicator_isVisibleAtPartialProgress() {
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.01))
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.5))
    XCTAssertTrue(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 0.999))
  }

  func test_shouldShowDownloadIndicator_isHiddenAtCompleteProgress() {
    XCTAssertFalse(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 1.0))
  }

  func test_shouldShowDownloadIndicator_isHiddenAboveCompleteProgress() {
    // Defensive: NetworkService now clamps to monotonic-max, but if a future change
    // ever published a value > 1, the indicator must remain hidden — not flicker on.
    XCTAssertFalse(AudiobookPlaybackModel.shouldShowDownloadIndicator(forOverallProgress: 1.5))
  }
}
