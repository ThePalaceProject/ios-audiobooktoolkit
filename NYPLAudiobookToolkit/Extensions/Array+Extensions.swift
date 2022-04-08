//
//  Array+Extensions.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 4/6/22.
//  Copyright © 2022 Dean Silfen. All rights reserved.
//

import Foundation

extension Array {
    mutating func append(_ element: Element?) {
        guard let element = element else { return }
        self.append(element)
    }
    
    subscript (safe index: Index) -> Iterator.Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
