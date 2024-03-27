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
    var tracks: [Track] = []
    var totalDuration: Int = 0
    
    init(manifest: Manifest) {
        self.manifest = manifest
        self.initializeTracks()
        self.calculateTotalDuration()
    }
    
    private func initializeTracks() {
        if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
            addTracksFromReadingOrder(readingOrder)
        } else {
            // If readingOrder is not available, attempt to initialize tracks from links.
            // You might need additional logic here if your manifest contains other fields that can be used to create tracks.
            addTracksFromLinks()
        }
    }
    
    private func addTracksFromReadingOrder(_ readingOrder: [Manifest.ReadingOrderItem]) {
        for (idx, item) in readingOrder.enumerated() {
            guard let track = createTrack(from: item, index: idx) else { continue }
            tracks.append(track)
        }
    }
    
    private func addTracksFromLinks() {
        // This function assumes that links can directly represent tracks.
        // Adjust the implementation as necessary based on the actual structure of your manifest.
        for (idx, link) in (manifest.links ?? []).enumerated() {
            if let type = link.type, type.contains("audio") {
                let title = link.title ?? link.href.components(separatedBy: "/").last ?? "Untitled"
                let duration = link.duration ?? 0 // Assume a default or calculate duration if possible.
                let track = Track(type: .href(link.href), title: title, duration: duration, index: idx)
                tracks.append(track)
            }
        }
    }
    
    private func createTrack(from item: Manifest.ReadingOrderItem, index: Int) -> Track? {
        guard let href = item.href else { return nil }
        let title = item.title ?? "Untitled"
        let duration = Int(item.duration) * 1000 // Convert to milliseconds if needed
        return Track(type: .href(href), title: title, duration: duration, index: index)
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
