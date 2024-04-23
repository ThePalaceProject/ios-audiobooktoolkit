//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Work on 3/25/24.
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
    
    public required convenience init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor? = nil) {
        self.init(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor, token: nil)
    }

    public init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor? = nil, token: String?) {
        super.init(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor)

        self.drmData["status"] = DRMStatus.succeeded
        self.token = token
        
        if let JSON = manifest.toJSONDictionary(), !FeedbookDRMProcessor.processManifest(JSON, drmData: &drmData) {
            ATLog(.error, "FeedbookDRMProcessor failed to pass JSON: \n\(JSON)")
            return nil
        }
    }
    
    public override func checkDrmAsync() {
        FeedbookDRMProcessor.performAsyncDrm(book: self, drmData: drmData)
    }
}
