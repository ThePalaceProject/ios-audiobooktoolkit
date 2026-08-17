//
//  AudiobookAccessibilityAnnouncementCenterTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by The Palace Project on 2/6/26.
//

import XCTest
@testable import PalaceAudiobookToolkit

@MainActor
final class AudiobookAccessibilityAnnouncementCenterTests: XCTestCase {

  /// Regression test for PP-3594: VoiceOver should announce audiobook download progress at throttled intervals.
  func testPP3594_intermediateDownloadProgress_isSuppressed_butStartStillAnnounces() {
    // Contract (commit 0d739944 "Silence intermediate download progress
    // VoiceOver announcements"): intermediate progress must NOT interrupt a
    // VoiceOver listener; only start/completion/failure announce. The previous
    // form of this test asserted per-step progress announcements, which the
    // suppression change deliberately removed — it was stale and failing.
    var announcements: [String] = []
    let announcer = AudiobookAccessibilityAnnouncementCenter(
      postHandler: { _, message in announcements.append(message) },
      isVoiceOverRunning: { true },
      progressStep: 20
    )

    // Positive control: start DOES announce, proving the post path is live
    // (so an empty result below means suppression, not a dead announcer).
    announcer.announceDownloadStarted(title: "Sample Audiobook")

    // Every intermediate progress tick must be silent.
    for progress in [0.10, 0.20, 0.25, 0.40, 1.00] {
      announcer.announceDownloadProgress(title: "Sample Audiobook", identifier: "audio-1", progress: progress)
    }

    // `announce` hops to the main queue; drain it so any erroneous progress
    // post would have landed before we assert.
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1.0)

    XCTAssertEqual(announcements.count, 1,
      "Only the start announcement should post; intermediate progress is suppressed.")
    XCTAssertFalse(announcements.contains { $0.localizedCaseInsensitiveContains("percent") },
      "No intermediate progress (percent) announcement should be posted.")
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
