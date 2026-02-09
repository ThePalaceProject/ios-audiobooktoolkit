//
//  AudiobookAccessibilityAnnouncementCenterTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by The Palace Project on 2/6/26.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class AudiobookAccessibilityAnnouncementCenterTests: XCTestCase {

  /// Regression test for PP-3594: VoiceOver should announce audiobook download progress at throttled intervals.
  func testPP3594_audiobookProgress_throttlesAnnouncements() {
    var announcements: [String] = []
    let expectedCount = 2
    let expectation = expectation(description: "Progress announcements posted")
    expectation.expectedFulfillmentCount = expectedCount

    let announcer = AudiobookAccessibilityAnnouncementCenter(
      postHandler: { _, message in
        announcements.append(message)
        expectation.fulfill()
      },
      isVoiceOverRunning: { true },
      progressStep: 20
    )

    announcer.announceDownloadProgress(title: "Sample Audiobook", identifier: "audio-1", progress: 0.10)
    announcer.announceDownloadProgress(title: "Sample Audiobook", identifier: "audio-1", progress: 0.20)
    announcer.announceDownloadProgress(title: "Sample Audiobook", identifier: "audio-1", progress: 0.25)
    announcer.announceDownloadProgress(title: "Sample Audiobook", identifier: "audio-1", progress: 0.40)
    announcer.announceDownloadProgress(title: "Sample Audiobook", identifier: "audio-1", progress: 1.00)

    wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(
      announcements,
      [
        "Download 20 percent complete for Sample Audiobook.",
        "Download 40 percent complete for Sample Audiobook."
      ]
    )
  }

  /// Regression test for PP-3594: VoiceOver announcements should not fire when VoiceOver is off.
  func testPP3594_audiobookAnnouncements_respectVoiceOverDisabled() {
    var announcements: [String] = []
    let announcer = AudiobookAccessibilityAnnouncementCenter(
      postHandler: { _, message in announcements.append(message) },
      isVoiceOverRunning: { false }
    )

    announcer.announceDownloadStarted(title: "Sample Audiobook")
    announcer.announceDownloadCompleted(title: "Sample Audiobook")

    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

    XCTAssertTrue(announcements.isEmpty)
  }
}
