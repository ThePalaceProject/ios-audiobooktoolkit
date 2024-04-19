//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public protocol Track: class, Identifiable {
    var key: String { get }
    var downloadTask: DownloadTask? { get }
    var title: String? { get }
    var index: Int { get }
    var duration: TimeInterval { get }
    var urls: [URL]? { get }
}

extension Track {
    public var id: String { key }
}
