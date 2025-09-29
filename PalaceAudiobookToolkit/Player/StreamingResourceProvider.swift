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

public protocol StreamingCapablePlayer: AnyObject {
  func publicationDidLoad()
  func setStreamingProvider(_ provider: StreamingResourceProvider)
}

// MARK: - LCPStreamingProvider

public protocol LCPStreamingProvider: DRMDecryptor, StreamingResourceProvider {
  func supportsStreaming() -> Bool
  func setupStreamingFor(_ player: Any) -> Bool
}
