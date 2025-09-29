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

  override public var drmStatus: DRMStatus {
    get {
      (drmData["status"] as? DRMStatus) ?? DRMStatus.succeeded
    }
    set {
      drmData["status"] = newValue
      player.isDrmOk = (DRMStatus.succeeded == newValue)
    }
  }

  private var drmData: [String: Any] = [:]

  public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor? = nil, token: String?) {
    super.init(manifest: manifest, bookIdentifier: bookIdentifier, decryptor: decryptor, token: token)

    drmData["status"] = DRMStatus.succeeded
    self.token = token

    if !FeedbookDRMProcessor.processManifest(manifest.toJSONDictionary()!, drmData: &drmData) {
      ATLog(.error, "FeedbookDRMProcessor failed processing")
      return nil
    }
  }

  override public func checkDrmAsync() {
    FeedbookDRMProcessor.performAsyncDrm(book: self, drmData: drmData)
  }
}
