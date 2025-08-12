//
//  StreamingResourceProvider.swift
//  PalaceAudiobookToolkit
//
//  Protocol for providing streaming resources to custom resource loaders.
//

import Foundation
import ReadiumShared

public protocol StreamingResourceProvider: AnyObject {
    func getPublication() -> Publication?
}

public protocol StreamingCapablePlayer: AnyObject {
    func setStreamingProvider(_ provider: StreamingResourceProvider)
}

public protocol LCPStreamingProvider: DRMDecryptor, StreamingResourceProvider {
    func supportsStreaming() -> Bool
    
    func setupStreamingFor(_ player: Any) -> Bool
}
