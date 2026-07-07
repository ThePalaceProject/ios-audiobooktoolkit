import Foundation

/// Bridge for the main app to provide the Palace auth token to the audiobook toolkit.
/// The main app sets `tokenResolver` at launch so the toolkit can refresh bearer
/// tokens using the correct credentials during streaming playback.
public enum PalaceAuthTokenProvider {
  private static let lock = NSLock()
  private static var _tokenResolver: (@Sendable () -> String?)?

  /// The main app installs a resolver at launch; the toolkit reads it from its
  /// networking layer (`OpenAccessDownloadTask` / `OpenAccessPlayer`) off the
  /// main thread during streaming playback. Under Swift 6 a bare
  /// `public static var` is shared mutable state and not concurrency-safe, so
  /// the storage is lock-guarded and the resolver closure is `@Sendable`. The
  /// accessors are synchronous, so `lock()`/`unlock()` are legal here (the
  /// async-context ban does not apply).
  public static var tokenResolver: (@Sendable () -> String?)? {
    get { lock.lock(); defer { lock.unlock() }; return _tokenResolver }
    set { lock.lock(); defer { lock.unlock() }; _tokenResolver = newValue }
  }

  public static var currentToken: String? {
    tokenResolver?()
  }
}
