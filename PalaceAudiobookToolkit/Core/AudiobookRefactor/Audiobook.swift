//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public struct AudiobookFactory {
    public static func audiobook(for manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor?, token: String?) -> Audiobook? {
        switch manifest.audiobookType {
        case .openAccess:
            return OpenAccessAudiobook(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor, token: token)
        default:
            return Audiobook(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor)
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

    public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor?) {
        self.uniqueId = bookIdentifier
        
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier)
        self.tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
        
        switch manifest.audiobookType {
        case .lcp:
            self.player = LCPPlayer(tableOfContents: tableOfContents, decryptor: decryptor)
        case .findaway:
            self.player = OpenAccessPlayer(tableOfContents: tableOfContents)
        default:
            self.player = OpenAccessPlayer(tableOfContents: tableOfContents)
        }

        super.init()
    }
    
    open func checkDrmAsync() {}
    
    open func deleteLocalContent(completion: @escaping (Bool, Error?) -> Void) {
        tableOfContents.tracks.deleteTracks()
        completion(true, nil)
    }
    
    open func update(manifest: Manifest, bookIdentifier: String) {
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier)
        self.tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
}

