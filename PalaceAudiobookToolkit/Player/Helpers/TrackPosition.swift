//
//  TrackPosition.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

enum TrackPositionError: Error, Equatable {
    case outOfBounds
    case tracksOutOfOrder
    case differentTracks
    case calculationError(String)
}

struct TrackPosition: Equatable, Comparable {
    var track: Track
    var timestamp: Int
    var tracks: Tracks
        
    static func - (lhs: TrackPosition, rhs: TrackPosition) throws -> Int {
        if lhs.track == rhs.track {
            return lhs.timestamp - rhs.timestamp
        }
        
        var diff = lhs.timestamp
        guard let lhsTrackIndex = lhs.tracks.tracks.firstIndex(where: { $0 == lhs.track }),
              let rhsTrackIndex = lhs.tracks.tracks.firstIndex(where: { $0 == rhs.track }) else {
            throw TrackPositionError.differentTracks
        }
        
        if lhsTrackIndex <= rhsTrackIndex {
            throw TrackPositionError.tracksOutOfOrder
        }
        
        for index in (rhsTrackIndex + 1)...lhsTrackIndex {
            diff += lhs.tracks.tracks[index].duration
        }
        
        diff += (lhs.tracks.tracks[rhsTrackIndex].duration - rhs.timestamp)
        return diff
    }
    
    static func + (lhs: TrackPosition, other: Int) throws -> TrackPosition {
        var newTimestamp = lhs.timestamp + other
        var currentTrack = lhs.track
        
        // Handle subtraction
        while newTimestamp < 0 {
            guard let prevTrack = lhs.tracks.previousTrack(currentTrack) else {
                throw TrackPositionError.outOfBounds
            }
            currentTrack = prevTrack
            newTimestamp += currentTrack.duration
        }
        
        // Handle positive addition
        while newTimestamp >= currentTrack.duration {
            newTimestamp -= currentTrack.duration
            guard let nextTrack = lhs.tracks.nextTrack(currentTrack) else {
                if newTimestamp == 0 {
                    // If exactly at the end of the last track, return this position
                    return TrackPosition(track: currentTrack, timestamp: newTimestamp, tracks: lhs.tracks)
                }
                throw TrackPositionError.outOfBounds
            }
            currentTrack = nextTrack
        }
        
        return TrackPosition(track: currentTrack, timestamp: newTimestamp, tracks: lhs.tracks)
    }

    static func < (lhs: TrackPosition, rhs: TrackPosition) -> Bool {
        if lhs.track == rhs.track {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.track < rhs.track
    }

    static func == (lhs: TrackPosition, rhs: TrackPosition) -> Bool {
        lhs.track == rhs.track && lhs.timestamp == rhs.timestamp
    }
}
