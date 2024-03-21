//
//  Tracks.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

class Tracks {
    var manifest: Manifest
    var tracks: [Track]
    var totalDuration: Int
    
    var count: Int {
        return tracks.count
    }
    
    init(manifest: Manifest) {
        self.manifest = manifest
        self.tracks = []
        self.totalDuration = 0
        
        for (idx, item) in manifest.readingOrder.enumerated() {
            var track: Track?
            
            if let href = item.href {
                track = Track(type: .href(href),
                              title: item.title,
                              duration: Int(item.duration) * 1000,
                              index: idx)
            } else if let part = item.findawayPart, let sequence = item.findawaySequence {
                track = Track(type: .findaway(part: part, sequence: sequence),
                              title: item.title,
                              duration: Int(item.duration) * 1000,
                              index: idx)
            }
            
            if let track = track {
                self.tracks.append(track)
            }
        }
        
        self.calculateTotalDuration()
    }
    
    func track(forHref href: String) -> Track? {
        return tracks.first(where: { track in
            if case let .href(trackHref) = track.type, trackHref == href {
                return true
            }
            return false
        })
    }
    
    func track(forPart part: Int, sequence: Int) -> Track? {
        return tracks.first(where: { track in
            if case let .findaway(trackPart, trackSequence) = track.type,
               trackPart == part && trackSequence == sequence {
                return true
            }
            return false
        })
    }
    
    func previousTrack(_ track: Track) -> Track? {
        guard let currentIndex = tracks.firstIndex(of: track), currentIndex > 0 else {
            return nil
        }
        return tracks[currentIndex - 1]
    }
    
    func nextTrack(_ track: Track) -> Track? {
        guard let currentIndex = tracks.firstIndex(of: track), currentIndex < tracks.count - 1 else {
            return nil
        }
        return tracks[currentIndex + 1]
    }
    
    subscript(index: Int) -> Track {
        return tracks[index]
    }
    
    func deleteTracks() {
        tracks.forEach { track in
            track.downloadTask?.delete()
        }
    }
    
    private func calculateTotalDuration() {
        self.totalDuration = tracks.reduce(0) { $0 + $1.duration }
    }
}
