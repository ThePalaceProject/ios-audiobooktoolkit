//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

public enum DRMStatus: Int {
    public typealias RawValue = Int
    case failed
    case processing
    case succeeded
    case unknown
}

/// DRM Decryptor protocol - decrypts protected files
@objc public protocol DRMDecryptor {
    
    /// Decrypt protected file
    /// - Parameters:
    ///   - url: encrypted file URL.
    ///   - resultUrl: URL to save decrypted file at.
    ///   - completion: decryptor callback with optional `Error`.
    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (_ error: Error?) -> Void)
    
    /// Optional: Get streamable URL for a track path (for true streaming without local files)
    /// - Parameters:
    ///   - trackPath: internal track path from manifest (e.g., "track1.mp3")
    ///   - completion: callback with streamable URL or error
    /// - Note: Default implementation returns nil (no streaming support)
    @objc optional func getStreamableURL(for trackPath: String, completion: @escaping (URL?, Error?) -> Void)
}

public struct AudiobookFactory {
    public static func audiobookClass(
        for manifest: Manifest
    ) -> Audiobook.Type {
        switch manifest.audiobookType {
        case .findaway:
            return FindawayAudiobook.self
        default:
            return OpenAccessAudiobook.self
        }
    }

    public static func audiobook(
        for manifest: Manifest,
        bookIdentifier: String,
        decryptor: DRMDecryptor?,
        token: String?
    ) -> Audiobook? {
        let cls = audiobookClass(for: manifest)
        return cls.init(
            manifest: manifest,
            bookIdentifier: bookIdentifier,
            decryptor: decryptor,
            token: token
        )
    }
}

open class Audiobook: NSObject {
    public var uniqueId: String
    public var annotationsId: String { uniqueId }
    public var tableOfContents: AudiobookTableOfContents
    public var player: Player
    public var drmStatus: DRMStatus {
        get {
            return DRMStatus.succeeded
        }
        set(newStatus) {
            player.isDrmOk = newStatus == DRMStatus.succeeded
        }
    }

    public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor?, token: String?) {
        self.uniqueId = bookIdentifier
        
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: token)
        self.tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
     
        let playerFactory = DynamicPlayerFactory()
        self.player = playerFactory.createPlayer(
            forType: manifest.audiobookType,
            withTableOfContents: tableOfContents,
            decryptor: decryptor
        )

        super.init()
    }
    
    open func checkDrmAsync() {}
    
    public class func deleteLocalContent(manifest: Manifest, bookIdentifier: String, token: String? = nil) {
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: token)
        let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
        tableOfContents.tracks.deleteTracks()
    }
    
    open func update(manifest: Manifest, bookIdentifier: String, token: String?) {
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: token)
        self.tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
}


protocol PlayerFactoryProtocol {
    func createPlayer(forType type: Manifest.AudiobookType, withTableOfContents toc: AudiobookTableOfContents, decryptor: DRMDecryptor?) -> Player
}

class DynamicPlayerFactory: PlayerFactoryProtocol {
    func createPlayer(forType type: Manifest.AudiobookType, withTableOfContents toc: AudiobookTableOfContents, decryptor: DRMDecryptor?) -> Player {
        switch type {
        case .lcp:
            if let streamingProvider = decryptor as? LCPStreamingProvider {
                if streamingProvider.supportsStreaming() {
                    let streamingPlayer = LCPStreamingPlayer(tableOfContents: toc, drmDecryptor: decryptor)
                    
                    let setupSuccess = streamingProvider.setupStreamingFor(streamingPlayer)
                    return streamingPlayer
                } else {
                    ATLog(.debug, "🏭 [PlayerFactory] Streaming not supported, using regular LCPPlayer")
                }
            } else {
                ATLog(.debug, "🏭 [PlayerFactory] Decryptor is not LCPStreamingProvider, using regular LCPPlayer")
            }
            
            ATLog(.debug, "🏭 [PlayerFactory] Creating fallback LCPPlayer")
            return LCPPlayer(tableOfContents: toc, decryptor: decryptor)
        case .findaway:
            return FindawayPlayer(tableOfContents: toc) ?? OpenAccessPlayer(tableOfContents: toc)
        default:
            return OpenAccessPlayer(tableOfContents: toc)
        }
    }
}
