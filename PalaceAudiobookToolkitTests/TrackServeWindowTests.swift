//
//  TrackServeWindowTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-5398 — a skip burst left serves for tracks the player had moved past
//  still reading. The loader buffers four tracks, so reads spread over more
//  than four displace each other's windows and every displaced read pays for a
//  whole archive fill.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class TrackServeWindowTests: XCTestCase {

  private let window = 4

  /// Inside the window nothing is abandoned.
  ///
  /// Steady playback reads the queued chapter and the preloaded following one,
  /// and a seek leaves the pair it supersedes draining, which is four tracks.
  /// All four are legitimate, so a bound at four must not touch them.
  func test_whenTheTracksInFlightFitTheWindow_nothingIsAbandoned() {
    let abandoned = TrackServeWindow.hrefsToAbandon(
      recencyOrder: ["ch9", "ch10", "ch8", "ch7"], window: window
    )
    XCTAssertTrue(abandoned.isEmpty, "four tracks is the widest set the player produces; none is stale")
  }

  /// Beyond the window the least recently active tracks are abandoned.
  func test_whenMoreTracksAreInFlightThanAreBuffered_theOldestAreAbandoned() {
    let abandoned = TrackServeWindow.hrefsToAbandon(
      recencyOrder: ["ch14", "ch13", "ch12", "ch11", "ch10", "ch9"], window: window
    )
    XCTAssertEqual(abandoned, ["ch10", "ch9"],
                   "only the tracks outside the four being buffered are abandoned")
  }

  /// The newest track is never abandoned.
  ///
  /// It is the chapter the patron is waiting for. Abandoning it would turn the
  /// stall this change is about into a chapter that never arrives.
  func test_theMostRecentlyActiveTrack_isNeverAbandoned() {
    let order = (0..<40).map { "ch\($0)" }
    let abandoned = TrackServeWindow.hrefsToAbandon(recencyOrder: order, window: window)

    XCTAssertFalse(abandoned.contains("ch0"), "the track the patron is waiting on must keep reading")
    XCTAssertEqual(abandoned.count, 36, "everything past the window is abandoned")
  }

  /// The preload target survives.
  ///
  /// The player preloads the following chapter once playback starts, so the two
  /// newest tracks must both keep reading or the bound would defeat the
  /// prefetch it is meant to protect.
  func test_theSecondMostRecentTrack_survivesSoThePreloadIsNotCancelled() {
    let abandoned = TrackServeWindow.hrefsToAbandon(
      recencyOrder: ["current", "following", "left", "older", "oldest"], window: window
    )
    XCTAssertFalse(abandoned.contains("following"), "the preloaded next chapter must not be abandoned")
    XCTAssertEqual(abandoned, ["oldest"])
  }

  // MARK: - Degenerate inputs

  /// A window of zero abandons nothing.
  ///
  /// A misconfigured bound must disable the behaviour rather than cancel every
  /// serve, which would stop playback altogether.
  func test_withAZeroWindow_nothingIsAbandoned() {
    XCTAssertTrue(
      TrackServeWindow.hrefsToAbandon(recencyOrder: ["a", "b", "c"], window: 0).isEmpty,
      "a window of zero must not be read as abandon everything"
    )
  }

  /// A negative window abandons nothing.
  func test_withANegativeWindow_nothingIsAbandoned() {
    XCTAssertTrue(
      TrackServeWindow.hrefsToAbandon(recencyOrder: ["a", "b", "c"], window: -1).isEmpty
    )
  }

  /// An empty flight set abandons nothing.
  func test_withNothingInFlight_nothingIsAbandoned() {
    XCTAssertTrue(TrackServeWindow.hrefsToAbandon(recencyOrder: [], window: window).isEmpty)
  }

  /// A repeated href is one track.
  ///
  /// AVFoundation issues several ranges for one track, and the loader buffers
  /// per track, so a duplicate must not consume a second slot in the window.
  func test_severalRangesOfOneTrack_countAsOneTrack() {
    let abandoned = TrackServeWindow.hrefsToAbandon(
      recencyOrder: ["ch9", "ch9", "ch9", "ch8", "ch7", "ch6"], window: window
    )
    XCTAssertTrue(abandoned.isEmpty,
                  "three ranges of ch9 plus three other tracks is four tracks, not six")
  }
}
