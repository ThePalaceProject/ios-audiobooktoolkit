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
