//
//  TrackPosition.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

struct TrackPosition: Equatable {
    var track: Track
    var timestamp: Int
    var tracks: Tracks
    
    static func - (lhs: TrackPosition, rhs: TrackPosition) -> Int? {
        guard lhs.track == rhs.track else {
            return nil
        }
        return lhs.timestamp - rhs.timestamp
    }
    
    static func + (lhs: TrackPosition, other: Int) -> TrackPosition {
        var newTimestamp = lhs.timestamp + other
        var newTrack = lhs.track
        
        if other < 0 {
            while newTimestamp < 0 {
                guard let prevTrack = lhs.tracks.previousTrack(newTrack) else {
                    fatalError("TrackPosition would be out of bounds")
                }
                newTrack = prevTrack
                newTimestamp += prevTrack.duration
            }
        } else {
            while newTimestamp > newTrack.duration {
                newTimestamp -= newTrack.duration
                guard let nextTrack = lhs.tracks.nextTrack(newTrack) else {
                    fatalError("TrackPosition would be out of bounds")
                }
                newTrack = nextTrack
            }
        }
        
        return TrackPosition(track: newTrack, timestamp: newTimestamp, tracks: lhs.tracks)
    }
    
    // Equatable protocol conformance
    static func == (lhs: TrackPosition, rhs: TrackPosition) -> Bool {
        return lhs.track == rhs.track && lhs.timestamp == rhs.timestamp
    }
}
