//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

struct Track: Codable {
    let href: String
    let title: String?
    let duration: Int
    let index: Int
}

extension Track: Equatable {
    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.index == rhs.index &&
        lhs.href == rhs.href &&
        lhs.duration == rhs.duration &&
        lhs.title == rhs.title
    }
}

extension Track: Comparable {
    static func < (lhs: Track, rhs: Track) -> Bool {
        lhs.href < rhs.href
    }
}
