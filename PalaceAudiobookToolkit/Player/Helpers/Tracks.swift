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
    var hrefToIndex: [String: Int]
    var totalDuration: Int
    
    init(manifest: Manifest) {
        self.manifest = manifest
        self.tracks = []
        self.hrefToIndex = [:]
        self.totalDuration = 0
        
        for (idx, track) in manifest.readingOrder.enumerated() {
            let tppTrack = Track(
                href: track.href,
                title: track.title,
                duration: Int(track.duration ?? 0) * 1000,
                index: idx
            )
            self.tracks.append(tppTrack)
            self.hrefToIndex[track.href] = idx
        }
        
        self.calculateTotalDuration()
    }
    
    func byHref(_ href: String) -> Track? {
        let cleanHref = href.components(separatedBy: "#").first ?? href
        guard let index = hrefToIndex[cleanHref] else { return nil }
        return tracks[index]
    }
    
    func previousTrack(_ track: Track) -> Track? {
        let idx = track.index
        return (idx - 1 >= 0) ? tracks[idx - 1] : nil
    }
    
    func nextTrack(_ track: Track) -> Track? {
        let idx = track.index
        return (idx + 1 < tracks.count) ? tracks[idx + 1] : nil
    }
    
    subscript(index: Int) -> Track {
        return tracks[index]
    }
    
    var count: Int {
        return tracks.count
    }
    
    private func calculateTotalDuration() {
        self.totalDuration = tracks.reduce(0) { $0 + $1.duration }
    }
}
