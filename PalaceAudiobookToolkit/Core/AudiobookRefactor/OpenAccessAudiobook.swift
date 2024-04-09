//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Work on 3/25/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

class OpenAccessAudiobook: Audiobook {
    override var drmStatus: DRMStatus {
        get {
            return (drmData["status"] as? DRMStatus) ?? DRMStatus.succeeded
        }
        set {
            drmData["status"] = newValue
//            player.isDrmOk = (DRMStatus.succeeded == newValue)
        }
    }
    
    private var drmData: [String: Any] = [:]
    
    public required init?(manifest: Manifest) {
        super.init(manifest: manifest)

        self.drmData["status"] = DRMStatus.succeeded
        
        if let JSON = manifest.toJSONDictionary(), !FeedbookDRMProcessor.processManifest(JSON, drmData: &drmData) {
            ATLog(.error, "FeedbookDRMProcessor failed to pass JSON: \n\(JSON)")
            return nil
        }
    }
    
    override func checkDrmAsync() {
        FeedbookDRMProcessor.performAsyncDrm(book: self, drmData: drmData)
    }
}
