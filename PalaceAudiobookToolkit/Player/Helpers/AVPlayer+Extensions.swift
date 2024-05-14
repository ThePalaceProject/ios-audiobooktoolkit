//
//  AVPlayer+Extensions.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/25/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import ObjectiveC
import AVFoundation

private var trackKey: UInt8 = 0

extension AVPlayerItem {
    var trackIdentifier: String? {
        get {
            return objc_getAssociatedObject(self, &trackKey) as? String
        }
        set {
            objc_setAssociatedObject(self, &trackKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
