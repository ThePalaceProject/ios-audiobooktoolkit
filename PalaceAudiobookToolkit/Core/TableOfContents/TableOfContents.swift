//
//  TableOfContents.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

@objc public class TableOfContents: NSObject {
    var manifest: Manifest
    var tracks: [Track]
    var chapter: [Chapter]
    
    init(manifest: Manifest) {
        self.manifest = manifest
        tracks = []
        chapter = []
    }
}
