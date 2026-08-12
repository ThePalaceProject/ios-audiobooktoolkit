import Foundation

/// Bridge for the main app to provide the Palace auth token to the audiobook toolkit.
/// The main app sets `tokenResolver` at launch so the toolkit can refresh bearer
/// tokens using the correct credentials during streaming playback.
public enum PalaceAuthTokenProvider {
  private static let _tokenResolver = LockIsolated<(@Sendable () -> String?)?>(nil)

  /// The main app installs a resolver at launch; the toolkit reads it from its
  /// networking layer (`OpenAccessDownloadTask` / `OpenAccessPlayer`) off the
  /// main thread during streaming playback. A bare `public static var` is
  /// shared mutable state and not concurrency-safe, so the storage lives in a
  /// `LockIsolated` box (an immutable `static let`, so the binding itself is
  /// not global mutable state) and the resolver closure is `@Sendable`.
  public static var tokenResolver: (@Sendable () -> String?)? {
    get { _tokenResolver.value }
    set { _tokenResolver.value = newValue }
  }

  public static var currentToken: String? {
    tokenResolver?()
  }
}
