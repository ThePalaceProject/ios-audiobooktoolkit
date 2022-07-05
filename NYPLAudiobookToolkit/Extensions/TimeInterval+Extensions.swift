//
//  TimeInterval+Extensions.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 6/30/22.
//  Copyright © 2022 Dean Silfen. All rights reserved.
//

import Foundation

extension TimeInterval {
    public var seconds: Int {
        Int(self.rounded())
    }

    public var milliseconds: Int {
        seconds * 1000
    }
}
