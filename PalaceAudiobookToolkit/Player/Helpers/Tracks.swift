//
//  Tracks.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

protocol Tracks {
    var manifest: Manifest { get }
    var tracks: [Tracks] { get }
    var hrefToIndex: [String: Int] { get }
    var totalDuration: Int { get }
    var count: Int { get }
    subscript(index: Int) -> Track { get }

    func byHref(_ href: String) -> Track?
    func previousTrack(_ track: Track) -> Track?
    func nextTrack(_ trAack: Track) -> Track?
}

class TPPTracks {
    var manifest: Manifest
    var tracks: [Track]
    var hrefToIndex: [String: Int]
    var totalDurationMs: Int
    
    init(manifest: Manifest) {
        self.manifest = manifest
        self.tracks = []
        self.hrefToIndex = [:]
        self.totalDurationMs = 0
        
        for (idx, track) in manifest.readingOrder.enumerated() {
            let tppTrack = Track(
                href: track.href,
                title: track.title,
                duration: track.duration ?? 0 * 1000,
                index: idx
            )
            self.tracks.append(tppTrack)
            self.hrefToIndex[track.href] = idx
        }
        
        self.calculateTotalDuration()
    }
    
    func byHref(_ href: String) -> Track? {
        guard let index = hrefToIndex[href] else { return nil }
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
        self.totalDurationMs = tracks.reduce(0) { $0 + $1.duration }
    }
}
