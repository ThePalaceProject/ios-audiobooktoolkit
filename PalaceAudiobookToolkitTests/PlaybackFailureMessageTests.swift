//
//  PlaybackFailureMessageTests.swift
//  PalaceAudiobookToolkitTests
//
//  Which message a playback failure is shown as. A timed-out read used to be
//  reported as a lost connection, so a patron with a working connection was
//  told it had dropped (PP-5398).
//

import XCTest
@testable import PalaceAudiobookToolkit

final class PlaybackFailureMessageTests: XCTestCase {
  private func urlError(_ code: Int) -> NSError {
    NSError(domain: NSURLErrorDomain, code: code)
  }

  /// A read that timed out is not a lost connection.
  func testTimedOutRead_isShownAsALoadThatTookTooLong() {
    XCTAssertEqual(OpenAccessPlayerError.forPlaybackFailure(urlError(NSURLErrorTimedOut)), .loadTimedOut)
  }

  /// A connection that really dropped keeps the lost-connection message.
  func testDroppedConnection_isShownAsConnectionLost() {
    XCTAssertEqual(
      OpenAccessPlayerError.forPlaybackFailure(urlError(NSURLErrorNetworkConnectionLost)),
      .connectionLost
    )
    XCTAssertEqual(
      OpenAccessPlayerError.forPlaybackFailure(urlError(NSURLErrorNotConnectedToInternet)),
      .connectionLost
    )
  }

  /// AVFoundation re-types an HTTP 403 as -1102 before it reaches the player.
  func testRetypedForbidden_isShownAsTitleUnavailable() {
    XCTAssertEqual(
      OpenAccessPlayerError.forPlaybackFailure(urlError(NSURLErrorNoPermissionsToReadFile)),
      .contentForbidden
    )
  }

  func testAuthenticationRequired_isShownAsSignInRequired() {
    XCTAssertEqual(
      OpenAccessPlayerError.forPlaybackFailure(urlError(NSURLErrorUserAuthenticationRequired)),
      .authenticationRequired
    )
  }

  /// An error the player raised itself carries its own case.
  func testPlayerError_isShownAsItsOwnCase() {
    let error = NSError(domain: OpenAccessPlayerErrorDomain, code: OpenAccessPlayerError.drmExpired.rawValue)
    XCTAssertEqual(OpenAccessPlayerError.forPlaybackFailure(error), .drmExpired)
  }

  /// Anything else has no specific message, so the generic one is shown.
  func testUnrecognisedOrMissingError_hasNoSpecificMessage() {
    XCTAssertNil(OpenAccessPlayerError.forPlaybackFailure(urlError(NSURLErrorBadURL)))
    XCTAssertNil(OpenAccessPlayerError.forPlaybackFailure(NSError(domain: "Other", code: 1)))
    XCTAssertNil(OpenAccessPlayerError.forPlaybackFailure(nil))
    XCTAssertNil(OpenAccessPlayerError.forPlaybackFailure(NSError(domain: OpenAccessPlayerErrorDomain, code: 999)))
  }
}
