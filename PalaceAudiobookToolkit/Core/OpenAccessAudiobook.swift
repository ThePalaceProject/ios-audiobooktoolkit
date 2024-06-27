//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/25/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public class OpenAccessAudiobook: Audiobook {
    public var token: String?

    public override var drmStatus: DRMStatus {
        get {
            return (drmData["status"] as? DRMStatus) ?? DRMStatus.succeeded
        }
        set {
            drmData["status"] = newValue
            player.isDrmOk = (DRMStatus.succeeded == newValue)
        }
    }
    
    private var drmData: [String: Any] = [:]

    public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor? = nil, token: String?) {
        super.init(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor, token: token)

        self.drmData["status"] = DRMStatus.succeeded
        self.token = token
        
        
        if !FeedbookDRMProcessor.processManifest(manifest, drmData: &drmData) {
            ATLog(.error, "FeedbookDRMProcessor failed processing")
            return nil
        }
    }
    
    public override func checkDrmAsync() {
        FeedbookDRMProcessor.performAsyncDrm(book: self, drmData: drmData)
    }
}
