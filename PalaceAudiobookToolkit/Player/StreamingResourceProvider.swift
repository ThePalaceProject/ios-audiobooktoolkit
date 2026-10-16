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
