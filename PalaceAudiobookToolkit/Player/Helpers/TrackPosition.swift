//
//  TrackPosition.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

struct TrackPosition {
    var track: Track
    var timeStamp: Int
    var tracks: Tracks
}

extension TrackPosition {
    static func - (lhs: TrackPosition, rhs: TrackPosition) -> Int {
        guard lhs.track == rhs.track else {
            fatalError("Subtracting track positions from different tracks is not supported")
        }

        return lhs.timeStamp - rhs.timeStamp
    }
}
