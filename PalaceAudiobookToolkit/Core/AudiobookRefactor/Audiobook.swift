//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation


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

open class Audiobook: NSObject, AudiobookProtocol {
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

            guard let playerClass = NSClassFromString("NYPLAEToolkit.FindawayPlayer") as? Player.Type,
                  let player = playerClass.init(tableOfContents: toc) else {
             fallthrough
            }

            return player
        default:
            return OpenAccessPlayer(tableOfContents: toc)
        }
    }
}
