//
//  FindawayAudiobook.swift
//  NYPLAEToolkit
//
//  Created by Maurice Carrier on 3/26/24.
//  Copyright © 2024 Dean Silfen. All rights reserved.
//

import UIKit
import AudioEngine

public final class FindawayAudiobook: Audiobook {
    public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor? = nil, token: String? = nil) {
        guard let fulfillmentId = type(of: self).getFulfillmentId(from: manifest) else {
            return nil
        }
        
        super.init(manifest: manifest, bookIdentifier: fulfillmentId, decryptor: decryptor, token: token)
        self.uniqueId = fulfillmentId
    }

    private class func getFulfillmentId(from manifest: Manifest) -> String? {
        return manifest.metadata?.drmInformation?.fulfillmentId
    }

    public override class func deleteLocalContent(manifest: Manifest, bookIdentifier: String, token: String? = nil) {
        guard let fulfillmentId = getFulfillmentId(from: manifest) else {
            return
        }
        FAEAudioEngine.shared()?.downloadEngine?.delete(forAudiobookID: fulfillmentId)
    }
}
