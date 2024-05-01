//
//  FindawayAudiobook.swift
//  NYPLAEToolkit
//
//  Created by Maurice Carrier on 3/26/24.
//  Copyright © 2024 Dean Silfen. All rights reserved.
//

import UIKit
import AudioEngine

private func findawayKey(_ key: String) -> String {
    return "findaway:\(key)"
}

public final class FindawayAudiobook: Audiobook {
    public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor? = nil, token: String? = nil) {
        super.init(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor, token: token)
        
        guard let findawayInfo = manifest.metadata?.drmInformation else {
            return nil
        }
    }
    
    public override func deleteLocalContent(completion: @escaping (Bool, Error?) -> Void) {
        FAEAudioEngine.shared()?.downloadEngine?.delete(forAudiobookID: self.uniqueId)
        completion(true, nil)
    }
}
