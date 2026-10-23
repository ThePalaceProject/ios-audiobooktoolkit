import Foundation

let OpenAccessPlayerErrorDomain = "org.nypl.labs.NYPLAudiobookToolkit.OpenAccessPlayer"
let OverdrivePlayerErrorDomain = "org.nypl.labs.NYPLAudiobookToolkit.OverdrivePlayer"

// MARK: - OpenAccessPlayerError

enum OpenAccessPlayerError: Int {
  case unknown = 0
  case downloadNotFinished
  case playerNotReady
  case connectionLost
  case drmExpired
  case authenticationRequired
  case contentForbidden
  case loadTimedOut

  /// The error a playback failure is shown as, or nil when it has no specific
  /// message.
  ///
  /// AVFoundation re-types errors on the way to the player item: an HTTP 403
  /// arrives as `NSURLErrorNoPermissionsToReadFile` (-1102), so it is read as
  /// `contentForbidden` and the patron sees "Title Unavailable".
  static func forPlaybackFailure(_ error: Error?) -> OpenAccessPlayerError? {
    guard let nsError = error as NSError? else { return nil }
    if nsError.domain == OpenAccessPlayerErrorDomain {
      return OpenAccessPlayerError(rawValue: nsError.code)
    }
    guard nsError.domain == NSURLErrorDomain else { return nil }
    switch nsError.code {
    case NSURLErrorNoPermissionsToReadFile:
      return .contentForbidden
    case NSURLErrorUserAuthenticationRequired:
      return .authenticationRequired
    case NSURLErrorNotConnectedToInternet,
         NSURLErrorNetworkConnectionLost:
      return .connectionLost
    case NSURLErrorTimedOut:
      // A read timing out says nothing about the connection: on a streamed
      // book it is usually a chapter waiting behind other reads (PP-5398).
      return .loadTimedOut
    default:
      return nil
    }
  }

  func errorTitle() -> String {
    switch self {
    case .downloadNotFinished:
      "Please Wait"
    case .connectionLost:
      "Connection Lost"
    case .drmExpired:
      "DRM Protection"
    case .authenticationRequired:
      "Sign In Required"
    case .contentForbidden:
      "Title Unavailable"
    case .loadTimedOut:
      "Still Loading"
    default:
      "A Problem Has Occurred"
    }
  }

  func errorDescription() -> String {
    switch self {
    case .unknown:
      """
      An unknown error has occurred. Please leave the book, and try again.
      If the problem persists, go to Settings and sign out.
      """
    case .downloadNotFinished:
      """
      This chapter has not finished downloading. Please wait and try again.
      """
    case .playerNotReady:
      """
      A problem has occurred. Please leave the book and try again.
      """
    case .connectionLost:
      """
      The internet connection was lost during the download.
       Wait until you are back online, leave the book and try again.
      """
    case .drmExpired:
      """
      DRM Permissions for this Audiobook have expired. Please leave the book, and try again.
      If the problem persists, go to Settings and sign out.
      """
    case .authenticationRequired:
      """
      Your session has expired. Please sign in to your library account to continue listening.
      """
    case .contentForbidden:
      """
      This audiobook is no longer available from the publisher. Please return it and try a \
      different title. If the problem persists, contact your library.
      """
    case .loadTimedOut:
      """
      This part of the audiobook took too long to load. Please try again.
      """
    }
  }
}

// MARK: - OverdrivePlayerError

enum OverdrivePlayerError: Int {
  // Cases 0 - 3 have to match with OpenAccessPlayerError
  // since they are thrown in OpenAccessPlayer, parent class of OverdrivePlayer
  case unknown = 0
  case downloadNotFinished
  case playerNotReady
  case connectionLost
  case downloadExpired

  func errorTitle() -> String {
    switch self {
    case .downloadNotFinished:
      "Please Wait"
    case .connectionLost:
      "Connection Lost"
    case .downloadExpired:
      "Download Expired"
    default:
      "A Problem Has Occurred"
    }
  }

  func errorDescription() -> String {
    switch self {
    case .unknown:
      """
      An unknown error has occurred. Please leave the book, and try again.
      If the problem persists, go to Settings and sign out.
      """
    case .downloadNotFinished:
      """
      This chapter has not finished downloading. Please wait and try again.
      """
    case .playerNotReady:
      """
      A problem has occurred. Please leave the book and try again.
      """
    case .connectionLost:
      """
      The internet connection was lost during the download.
       Wait until you are back online, leave the book and try again.
      """
    case .downloadExpired:
      """
      The download URLs for this Audiobook have expired. Please leave the book, and try again.
      """
    }
  }
}
