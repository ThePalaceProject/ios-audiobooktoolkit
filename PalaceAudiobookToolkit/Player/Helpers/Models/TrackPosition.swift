//
//  TrackPosition.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public enum TrackPositionError: Error, Equatable {
    case outOfBounds
    case tracksOutOfOrder
    case differentTracks
    case calculationError(String)
}

public struct TrackPosition: Equatable, Comparable {
    public var track: any Track
    public var timestamp: Double
    public var tracks: Tracks
    public var lastSavedTimeStamp: String = ""
    public var annotationId: String = ""

    public init(track: any Track, timestamp: Double, tracks: Tracks) {
        self.track = track
        self.timestamp = timestamp
        self.tracks = tracks
    }
    
    public static func - (lhs: TrackPosition, rhs: TrackPosition) throws -> Double {
        if lhs.track.id == rhs.track.id {
            return lhs.timestamp - rhs.timestamp
        }

        guard let lhsTrackIndex = lhs.tracks.tracks.firstIndex(where: { $0.id == lhs.track.id }),
              let rhsTrackIndex = lhs.tracks.tracks.firstIndex(where: { $0.id == rhs.track.id }) else {
            throw TrackPositionError.differentTracks
        }

        var diff = 0.0

        if lhsTrackIndex > rhsTrackIndex {
            diff += rhs.track.duration - rhs.timestamp

            for index in (rhsTrackIndex + 1)..<lhsTrackIndex {
                diff += lhs.tracks[index].duration
            }

            diff += lhs.timestamp
        } else {
            diff -= lhs.timestamp

            for index in (lhsTrackIndex + 1)..<rhsTrackIndex {
                diff -= lhs.tracks[index].duration
            }

            diff -= rhs.track.duration - rhs.timestamp

            return -diff
        }

        return diff
    }

    public static func + (lhs: TrackPosition, other: Double) -> TrackPosition {
        var newTimestamp = lhs.timestamp + other
        var currentTrack = lhs.track

        while newTimestamp < 0 {
            guard let prevTrack = lhs.tracks.previousTrack(currentTrack) else {
                return TrackPosition(track: currentTrack, timestamp: 0, tracks: lhs.tracks)
            }
            currentTrack = prevTrack
            newTimestamp += currentTrack.duration
        }

        while newTimestamp >= currentTrack.duration {
            newTimestamp -= currentTrack.duration
            guard let nextTrack = lhs.tracks.nextTrack(currentTrack) else {
                return TrackPosition(track: currentTrack, timestamp: currentTrack.duration, tracks: lhs.tracks)
            }
            currentTrack = nextTrack
        }

        return TrackPosition(track: currentTrack, timestamp: newTimestamp, tracks: lhs.tracks)
    }


    public static func < (lhs: TrackPosition, rhs: TrackPosition) -> Bool {
        if lhs.track.id == rhs.track.id {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.track.index < rhs.track.index
    }

    public static func == (lhs: TrackPosition, rhs: TrackPosition) -> Bool {
        lhs.track.id == rhs.track.id && Int(lhs.timestamp) == Int(rhs.timestamp)
    }
}

extension TrackPosition: CustomStringConvertible {
    public var description: String {
        let trackDesc = track.description
        return "Track: \(trackDesc) (Timestamp: \(timestamp)"
    }
    
    public func durationToSelf() -> TimeInterval {
        tracks.duration(to: self)
    }
}
