//
//  TimeInterval+Extensions.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 6/30/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

public extension TimeInterval {
  var seconds: Int {
    Int(rounded())
  }

  var milliseconds: Int {
    seconds * 1000
  }
}
