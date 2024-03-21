//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public final class Audiobook: NSObject, AudiobookProtocol {
    public let uniqueId: String
    public var annotationsId: String { uniqueId }
    public var tableOfContents: TableOfContents
    public let player: Player? = nil
    public var drmStatus: DRMStatus {
        get {
            return DRMStatus.succeeded
        }
        set(newStatus) {
            //            player.isDrmOk = newStatus == DRMStatus.succeeded
        }
    }

    public required init?(manifest: Manifest, audiobookId: String) {
        self.uniqueId = audiobookId
        
        let tracks = Tracks(manifest: manifest)
        self.tableOfContents = TableOfContents(manifest: manifest, tracks: tracks)
        
        super.init()
    }
    
    public func checkDrmAsync(completion: @escaping (Bool, Error?) -> Void) {
        completion(true, nil)
    }
    
    public func deleteLocalContent(completion: @escaping (Bool, Error?) -> Void) {
        tableOfContents.tracks.deleteTracks()
        completion(true, nil)
    }
    
    public func update(manifest: Manifest) {
        let tracks = Tracks(manifest: manifest)
        self.tableOfContents = TableOfContents(manifest: manifest, tracks: tracks)
    }
}

