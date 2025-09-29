//
//  FindawayAudiobook.swift
//  NYPLAEToolkit
//
//  Created by Maurice Carrier on 3/26/24.
//  Copyright © 2024 Dean Silfen. All rights reserved.
//

import AudioEngine
import UIKit

public final class FindawayAudiobook: Audiobook {
  public required init?(
    manifest: Manifest,
    bookIdentifier _: String,
    decryptor: DRMDecryptor? = nil,
    token: String? = nil
  ) {
    guard let fulfillmentId = type(of: self).getFulfillmentId(from: manifest) else {
      return nil
    }

    super.init(manifest: manifest, bookIdentifier: fulfillmentId, decryptor: decryptor, token: token)
    uniqueId = fulfillmentId
  }

  private class func getFulfillmentId(from manifest: Manifest) -> String? {
    manifest.metadata?.drmInformation?.fulfillmentId
  }

  override public class func deleteLocalContent(manifest: Manifest, bookIdentifier _: String, token _: String? = nil) {
    guard let fulfillmentId = getFulfillmentId(from: manifest) else {
      return
    }
    FAEAudioEngine.shared()?.downloadEngine?.delete(forAudiobookID: fulfillmentId)
  }
}
