//
//  MockTracks.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 3/18/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class MockTracks: Tracks {
    var manifest: Manifest
    var tracks: [Track]
    var hrefToIndex: [String: Int]
    var totalDuration: Int
    var count: Int { tracks.count }
    
    init(tracks: [Track], manifest: Manifest) {
        self.tracks = tracks
        self.hrefToIndex = tracks.enumerated().reduce(into: [String: Int]()) { $0[$1.element.href] = $1.offset }
        self.totalDuration = tracks.reduce(0) { $0 + $1.duration }
        self.manifest = manifest
    }
    
    subscript(index: Int) -> Track {
        return tracks[index]
    }
    
    func byHref(_ href: String) -> Track? {
        guard let index = hrefToIndex[href] else { return nil }
        return tracks[index]
    }
    
    func previousTrack(_ track: Track) -> Track? {
        guard let index = hrefToIndex[track.href], index > 0 else { return nil }
        return tracks[index - 1]
    }
    
    func nextTrack(_ track: Track) -> Track? {
        guard let index = hrefToIndex[track.href], index < tracks.count - 1 else { return nil }
        return tracks[index + 1]
    }
}

