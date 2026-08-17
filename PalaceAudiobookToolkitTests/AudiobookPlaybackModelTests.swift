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

  // MARK: - PP-4971 — remaining time is wall-clock, not book time
  //
  // `timeLeftInBook` is book time: how much recording is left. A listener at 2×
  // finishes a 60-minute remainder in 30 minutes, so the figure we SHOW must be
  // divided by the speed multiplier. Shipping book time told one reviewer hours
  // remained on a book they were about to finish.
  //
  // The rule lives on `remainingWallClock(bookTimeRemaining:rate:)`, a static
  // whose signature REQUIRES a rate — a caller cannot render remaining time
  // without supplying one, so the defect cannot be reintroduced by forgetting.

  func test_remainingWallClock_atNormalSpeed_isUnchanged() {
    XCTAssertEqual(
      AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 3600, rate: .normalTime),
      3600, accuracy: 0.001
    )
  }

  func test_remainingWallClock_atDoubleSpeed_isHalved() {
    XCTAssertEqual(
      AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 3600, rate: .doubleTime),
      1800, accuracy: 0.001
    )
  }

  func test_remainingWallClock_belowNormalSpeed_takesLonger() {
    // 0.75× — an hour of recording takes eighty minutes to hear.
    XCTAssertEqual(
      AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 3600, rate: .threeQuartersTime),
      4800, accuracy: 0.001
    )
  }

  func test_remainingWallClock_scalesAcrossTheEntireSpeedRail() {
    // PP-4518 extended the rail to 0.50×–3.00× in 0.05 steps. Every step must
    // divide, not just the six presets — a table test rather than three samples.
    for rate in PlaybackRate.allCases {
      let multiplier = Double(PlaybackRate.convert(rate: rate))
      XCTAssertEqual(
        AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 7200, rate: rate),
        7200 / multiplier, accuracy: 0.001,
        "rate \(rate.rawValue) did not scale the remaining time"
      )
    }
  }

  func test_remainingWallClock_finishedBookReadsZeroAtEverySpeed() {
    for rate in PlaybackRate.allCases {
      XCTAssertEqual(
        AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: 0, rate: rate),
        0, accuracy: 0.001,
        "rate \(rate.rawValue) did not report a finished book as zero"
      )
    }
  }

  func test_remainingWallClock_rejectsNonFiniteAndNegativeInput() {
    // `timeLeftInBook` can go negative if the playhead overruns the manifest
    // duration, and non-finite if a track reports a bad duration. Neither may
    // reach the label as "-1 min remaining" or "nan".
    XCTAssertEqual(AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: .infinity, rate: .doubleTime), 0)
    XCTAssertEqual(AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: .nan, rate: .doubleTime), 0)
    XCTAssertEqual(AudiobookPlaybackModel.remainingWallClock(bookTimeRemaining: -60, rate: .doubleTime), 0)
  }
}
