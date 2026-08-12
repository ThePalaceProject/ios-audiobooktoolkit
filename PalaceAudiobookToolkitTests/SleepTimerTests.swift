//
//  SleepTimerTests.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Dean Silfen on 3/7/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class SleepTimerTests: XCTestCase {
  lazy var tableOfContents: AudiobookTableOfContents = {
    let manifest = try! loadManifest(for: ManifestJSON.alice)
    return AudiobookTableOfContents(
      manifest: manifest,
      tracks: Tracks(manifest: manifest, audiobookID: "TEST_ID", token: nil)
    )
  }()

  func testIsScheduled() {
    let sleepTimer = SleepTimer(player: PlayerMock(tableOfContents: tableOfContents))
    XCTAssertFalse(sleepTimer.isActive)
    sleepTimer.setTimerTo(trigger: .fifteenMinutes)
    XCTAssertTrue(sleepTimer.isActive)
  }

  func testCancelSchedule() {
    let sleepTimer = SleepTimer(player: PlayerMock(tableOfContents: tableOfContents))
    sleepTimer.setTimerTo(trigger: .thirtyMinutes)
    XCTAssertTrue(sleepTimer.isActive)
    XCTAssertNotEqual(sleepTimer.timeRemaining, 0)
    sleepTimer.setTimerTo(trigger: .never)
    XCTAssertFalse(sleepTimer.isActive)
    XCTAssertEqual(sleepTimer.timeRemaining, 0)
  }

  /// `.endOfChapter` works differently from other triggers.
  /// Instead of keeping track of the time, it simply listens to
  /// `Player` and waits for the player to report that the
  /// current chapter has finished.
  func testTestEndOfChapter() {
    let playerMock = PlayerMock(tableOfContents: tableOfContents)
    
    // Set the current chapter - required for endOfChapter to activate
    if let firstChapter = tableOfContents.toc.first {
      playerMock.currentChapter = firstChapter
      playerMock.currentTrackPosition = firstChapter.position
    }

    let sleepTimer = SleepTimer(player: playerMock)
    sleepTimer.setTimerTo(trigger: .endOfChapter)
    XCTAssertTrue(sleepTimer.isActive)
  }

  func testTimeDecreases() {
    let expectTimeToDecrease = expectation(description: "time to decrease")
    let player = PlayerMock(tableOfContents: tableOfContents)
    player.isPlaying = true
    let sleepTimer = SleepTimer(player: player)
    sleepTimer.setTimerTo(trigger: .fifteenMinutes)
    let fourteenMinutesAndFiftyEightSeconds: TimeInterval = (60 * 14) + 58
    asyncCheckFor(
      sleepTimer: sleepTimer,
      untilTime: fourteenMinutesAndFiftyEightSeconds,
      theExpectation: expectTimeToDecrease
    )
    wait(for: [expectTimeToDecrease], timeout: 4)
  }

  func testIsAbleToSetDifferentTimes() {
    let expectTimeToDecreaseFrom15Minutes = expectation(description: "time to decrease from 15 minutes")
    let player = PlayerMock(tableOfContents: tableOfContents)
    player.isPlaying = true
    let sleepTimer = SleepTimer(player: player)
    sleepTimer.setTimerTo(trigger: .fifteenMinutes)
    XCTAssert(sleepTimer.isActive)
    let fourteenMinutesAndFiftyEightSeconds: TimeInterval = (60 * 14) + 58
    asyncCheckFor(
      sleepTimer: sleepTimer,
      untilTime: fourteenMinutesAndFiftyEightSeconds,
      theExpectation: expectTimeToDecreaseFrom15Minutes
    )
    wait(for: [expectTimeToDecreaseFrom15Minutes], timeout: 4)
    sleepTimer.setTimerTo(trigger: .never)
    XCTAssertFalse(sleepTimer.isActive)
    XCTAssertEqual(sleepTimer.timeRemaining, 0)

    sleepTimer.setTimerTo(trigger: .oneHour)
    XCTAssert(sleepTimer.isActive)
    let expectTimeToDecreaseFrom59Minutes = expectation(description: "time to decrease from 15 minutes")
    let fiftyNineMinutesAndFiftyEightSeconds: TimeInterval = (60 * 59) + 58
    asyncCheckFor(
      sleepTimer: sleepTimer,
      untilTime: fiftyNineMinutesAndFiftyEightSeconds,
      theExpectation: expectTimeToDecreaseFrom59Minutes
    )
    wait(for: [expectTimeToDecreaseFrom59Minutes], timeout: 4)
  }

  /// The 45-minute option has to schedule sleep 45 minutes out — not 30, not 60.
  /// Paused is the deterministic way to read the scheduled interval back
  /// without racing a countdown.
  func testFortyFiveMinutes_SchedulesSleepFortyFiveMinutesOut() {
    let player = PlayerMock(tableOfContents: tableOfContents)
    player.isPlaying = false
    let sleepTimer = SleepTimer(player: player)

    sleepTimer.setTimerTo(trigger: .fortyFiveMinutes)

    XCTAssertTrue(sleepTimer.isActive)
    XCTAssertEqual(sleepTimer.timeRemaining, 60 * 45)
  }

  /// While playing, the 45-minute timer counts down from 45 minutes — proving the
  /// trigger arms a real deadline rather than parking a static interval.
  func testFortyFiveMinutes_CountsDownWhilePlaying() {
    let expectTimeToDecrease = expectation(description: "time to decrease from 45 minutes")
    let player = PlayerMock(tableOfContents: tableOfContents)
    player.isPlaying = true
    let sleepTimer = SleepTimer(player: player)

    sleepTimer.setTimerTo(trigger: .fortyFiveMinutes)

    let fortyFourMinutesAndFiftyEightSeconds: TimeInterval = (60 * 44) + 58
    asyncCheckFor(
      sleepTimer: sleepTimer,
      untilTime: fortyFourMinutesAndFiftyEightSeconds,
      theExpectation: expectTimeToDecrease
    )
    wait(for: [expectTimeToDecrease], timeout: 4)
    XCTAssertGreaterThan(sleepTimer.timeRemaining, 60 * 44)
  }

  /// Both sleep-timer menus — the sheet player's action sheet and the in-app
  /// player's `Menu` — are built by iterating `allCases` and labelling each case
  /// with `displayTitle`, so this is literally the list of options a patron sees,
  /// in order. Pinning it catches a case appended to the end of the enum (which
  /// would list "45 Minutes" after "End of Chapter" yet still keep a
  /// duration-only test green) as well as a mislabelled option.
  func testSleepTimerMenu_OffersAscendingDurationsThenEndOfChapter() {
    XCTAssertEqual(
      SleepTimerTriggerAt.allCases.map(\.displayTitle),
      ["Off", "15 Minutes", "30 Minutes", "45 Minutes", "60 Minutes", "End of Chapter"]
    )
  }

  func testOnlyCountsDownWhilePlaying() {
    let player = PlayerMock(tableOfContents: tableOfContents)
    player.isPlaying = false
    let sleepTimer = SleepTimer(player: player)
    sleepTimer.setTimerTo(trigger: .fifteenMinutes)
    XCTAssert(sleepTimer.isActive)
    Thread.sleep(until: Date().addingTimeInterval(2))
    XCTAssertEqual(sleepTimer.timeRemaining, 60 * 15)
  }

  func asyncCheckFor(sleepTimer: SleepTimer, untilTime time: TimeInterval, theExpectation: XCTestExpectation) {
    let tts = sleepTimer.timeRemaining
    if tts < time && tts > 0 {
      theExpectation.fulfill()
    } else {
      DispatchQueue.main.async { [weak self] () in
        self?.asyncCheckFor(sleepTimer: sleepTimer, untilTime: time, theExpectation: theExpectation)
      }
    }
  }

  func loadManifest(for manifestJSON: ManifestJSON) throws -> Manifest {
    try Manifest.from(jsonFileName: manifestJSON.rawValue, bundle: Bundle(for: type(of: self)))
  }
}
