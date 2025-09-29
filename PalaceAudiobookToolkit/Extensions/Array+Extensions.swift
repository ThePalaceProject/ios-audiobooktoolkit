//
//  Array+Extensions.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/6/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension Array {
  mutating func append(_ element: Element?) {
    guard let element = element else {
      return
    }
    append(element)
  }

  subscript(safe index: Index) -> Iterator.Element? {
    indices.contains(index) ? self[index] : nil
  }
}
