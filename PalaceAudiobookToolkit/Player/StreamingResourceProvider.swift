//
//  StreamingResourceProvider.swift
//  PalaceAudiobookToolkit
//
//  Protocol for providing streaming resources to custom resource loaders.
//

import Foundation
import ReadiumShared

// MARK: - StreamingResourceProvider

public protocol StreamingResourceProvider: AnyObject {
  func getPublication() -> Publication?

  /// Whether the archive behind the publication is a local file rather than a
  /// remote one.
  ///
  /// Readium sizes its archive buffer on the same distinction
  /// (`ZIPFoundationArchiveFactory`: 16 kB and no buffering wrapper for a
  /// file, 6 MB for anything else), and the loader's per-track buffer only
  /// pays for itself against a remote origin. Over a local file it would read
  /// and decrypt a whole window to serve one segment and save nothing, because
  /// there is no request to avoid making.
  func archiveIsLocalFile() -> Bool

  /// What the archive's HTTP client has fetched from the origin so far, as
  /// (requests, bytes), for diagnosing a slow chapter change.
  ///
  /// The loader cannot reach that client — the app builds it and injects it
  /// into Readium — so the provider is the seam. A default of (0, 0) keeps
  /// every other provider unchanged; it reports "unknown", and the log says so.
  func archiveOriginActivity() -> (requests: Int, bytes: Int)

  /// The plaintext length already known for `href`, if any.
  ///
  /// Learning it costs a read of the entry's CBC tail, and that read is far
  /// from the audio in the archive, so it was measured at 17.8-28.8 MB of
  /// origin traffic to serve zero bytes of audio. The archive is immutable, so
  /// the answer is worth keeping.
  func cachedPlaintextLength(forHref href: String) -> UInt64?

  /// Records a plaintext length just learned, so no later session pays for it.
  func cachePlaintextLength(_ length: UInt64, forHref href: String)

  /// The track's plaintext length, waiting up to `timeout` for a resolution
  /// the provider already has running for this archive.
  ///
  /// Both answers to the same question cost very differently. A provider that
  /// reads the archive directly needs two small ranges per track; Readium's
  /// tail probe reads the entry's last AES blocks through the archive's shared
  /// window, measured on device at 18.6 MB of origin traffic to deliver two
  /// bytes. So the loader asks here first and only probes when the answer is
  /// nil, which means nothing is coming: a local package, a provider that
  /// resolves nothing, or a resolution that has already ended without this
  /// track.
  ///
  /// The default answers from the cache without waiting, so a provider that
  /// has not been taught this is unchanged.
  func plaintextLength(forHref href: String, waitingUpTo timeout: TimeInterval) async -> UInt64?

  /// Whether this track's opening bytes are already on disk, so the read that
  /// starts it costs no origin traffic.
  ///
  /// Asked to decide whether a chapter start is worth explaining to the
  /// patron. A track's plaintext LENGTH cannot answer it: the app learns every
  /// track's length from the archive directory in one pass, without reading a
  /// byte of audio, so a known length says nothing about whether the audio is
  /// near.
  ///
  /// The default is `true` — "assume the bytes are near". An unbound witness
  /// then shows no panel rather than showing one on every chapter, because a
  /// panel over a fast chapter is the failure this question exists to avoid.
  func trackHeadIsCached(forHref href: String) -> Bool

  /// The player has started a streaming load the patron is waiting on, and
  /// will call `streamingLoadDidEnd()` when that load finishes, fails or is
  /// torn down.
  ///
  /// Palace fetches the whole package in the background while streaming
  /// serves playback (PP-5135). The two transfers are separate URLSessions
  /// over one link, so the background fetch competes with the chapter the
  /// patron is waiting for, and a cross-chapter seek then exceeds the load
  /// timeout. A provider implements this pair to let the chapter have the
  /// link first; neither hook fetches anything, so egress is unchanged.
  ///
  /// Called once per load event, on the main queue, and paired: a seek to
  /// another chapter is a new load and calls `streamingLoadDidBegin()` again.
  ///
  /// Deliberately without a default implementation, unlike
  /// `archiveIsLocalFile()` above: a witness that fails to bind falls back to
  /// the default and disables the behaviour with no diagnostic.
  func streamingLoadDidBegin()

  /// The load announced by `streamingLoadDidBegin()` is over — loaded, failed,
  /// timed out or torn down. See that method; also without a default.
  func streamingLoadDidEnd()
}

public extension StreamingResourceProvider {
  /// Remote is the safe default: it keeps the per-track buffer, so a provider
  /// that has not been taught the difference still gets the egress fix.
  func archiveIsLocalFile() -> Bool { false }
  func archiveOriginActivity() -> (requests: Int, bytes: Int) { (0, 0) }
  func cachedPlaintextLength(forHref href: String) -> UInt64? { nil }
  func cachePlaintextLength(_ length: UInt64, forHref href: String) {}
  func plaintextLength(forHref href: String, waitingUpTo _: TimeInterval) async -> UInt64? {
    cachedPlaintextLength(forHref: href)
  }
  func trackHeadIsCached(forHref _: String) -> Bool { true }
}

// MARK: - StreamingCapablePlayer

/// Isolated with `Player`, which every conformer also adopts.
@MainActor
public protocol StreamingCapablePlayer: AnyObject {
  func publicationDidLoad()
  func setStreamingProvider(_ provider: StreamingResourceProvider)

  /// Whether playback is currently served from a remote archive.
  ///
  /// Prefetching whole tracks competes with the chapter the patron is waiting
  /// on when both cross the same link, and the prefetch is far the larger of
  /// the two: a track is read and decrypted in full, three at a time, while a
  /// cold chapter needs about 12.7 MB. Callers that can defer work until the
  /// archive is local ask here first.
  ///
  /// Deliberately without a default implementation: a witness that fails to
  /// bind would silently report the local case and restore the competition.
  var isServingRemoteArchive: Bool { get }
}

// MARK: - LCPStreamingProvider

public protocol LCPStreamingProvider: DRMDecryptor, StreamingResourceProvider {
  func supportsStreaming() -> Bool
  /// `@MainActor`: it is handed a `StreamingCapablePlayer` and calls
  /// `setStreamingProvider` on it, which is main-actor state. The only caller,
  /// `DynamicPlayerFactory`, is already isolated. `supportsStreaming()` stays
  /// nonisolated — it is a pure capability check.
  @MainActor func setupStreamingFor(_ player: Any) -> Bool
}
