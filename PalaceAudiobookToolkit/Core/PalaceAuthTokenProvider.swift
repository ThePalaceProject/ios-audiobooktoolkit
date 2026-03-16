import Foundation

/// Bridge for the main app to provide the Palace auth token to the audiobook toolkit.
/// The main app sets `tokenResolver` at launch so the toolkit can refresh bearer
/// tokens using the correct credentials during streaming playback.
public enum PalaceAuthTokenProvider {
  public static var tokenResolver: (() -> String?)? = nil

  public static var currentToken: String? {
    tokenResolver?()
  }
}
