//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

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
}

public struct AudiobookFactory {
    public static func audiobook(
        for manifest: Manifest,
        bookIdentifier: String,
        decryptor: DRMDecryptor?,
        token: String?
    ) -> Audiobook? {
        switch manifest.audiobookType {
        case .findaway:
            return FindawayAudiobook(
                manifest: manifest,
                bookIdentifier: bookIdentifier,
                token: token
            )
        default:
            return OpenAccessAudiobook(
                manifest: manifest,
                bookIdentifier: bookIdentifier,
                decryptor: decryptor,
                token: token
            )
        }
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
    
    open func deleteLocalContent(completion: @escaping (Bool, Error?) -> Void) {
        tableOfContents.tracks.deleteTracks()
        completion(true, nil)
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
            return LCPPlayer(tableOfContents: toc, decryptor: decryptor)
        case .findaway:
            return FindawayPlayer(tableOfContents: toc) ?? OpenAccessPlayer(tableOfContents: toc)
        default:
            return OpenAccessPlayer(tableOfContents: toc)
        }
    }
}
