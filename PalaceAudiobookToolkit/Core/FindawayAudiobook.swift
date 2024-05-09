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
        guard let fulfillmentId = manifest.metadata?.drmInformation?.fulfillmentId else {
            return nil
        }
        
        super.init(manifest: manifest, bookIdentifier: fulfillmentId, decryptor: decryptor, token: token)
        self.uniqueId = fulfillmentId
    }
    
    public override func deleteLocalContent(completion: @escaping (Bool, Error?) -> Void) {
        FAEAudioEngine.shared()?.downloadEngine?.delete(forAudiobookID: self.uniqueId)
        completion(true, nil)
    }
}
