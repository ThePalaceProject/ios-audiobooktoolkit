//
//  Data+hexString.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 17/08/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension Data {
    var hexString: String {
        self.map { String(format: "%02hhx", $0) }.joined()
    }
}
