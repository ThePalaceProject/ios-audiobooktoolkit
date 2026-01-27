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
