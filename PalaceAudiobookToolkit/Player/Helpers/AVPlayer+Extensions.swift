//
//  AVPlayer+Extensions.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/25/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import ObjectiveC

/// Replaces the classic `private var trackKey: UInt8 = 0` + `&trackKey` idiom,
/// which strict concurrency checking diagnoses as global mutable state. See
/// `AssociatedObjectKey` for why an identity-only pointer is safe to share.
private let trackKey = AssociatedObjectKey()

extension AVPlayerItem {
  var trackIdentifier: String? {
    get {
      objc_getAssociatedObject(self, trackKey.rawValue) as? String
    }
    set {
      objc_setAssociatedObject(self, trackKey.rawValue, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}
