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
