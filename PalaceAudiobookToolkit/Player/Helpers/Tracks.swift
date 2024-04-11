//
//  Tracks.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public class Tracks {
    var manifest: Manifest
    public var tracks: [Track] = []
    public var totalDuration: Double = 0
    
    init(manifest: Manifest) {
        self.manifest = manifest
        self.initializeTracks()
        self.calculateTotalDuration()
    }

    private func initializeTracks() {
        if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
            addTracksFromReadingOrder(readingOrder)
        } else if let linksDict = manifest.linksDictionary, let contentLinks = linksDict.contentLinks, !contentLinks.isEmpty {
            addTracksFromLinks(contentLinks)
        } else if let linksArray = manifest.links, !linksArray.isEmpty {
            addTracksFromLinks(linksArray)
        }
    }
    
    private func addTracksFromReadingOrder(_ readingOrder: [Manifest.ReadingOrderItem]) {
        for (index, item) in readingOrder.enumerated() {
            if let track = createTrack(from: item, index: index) {
                tracks.append(track)
            }
        }
    }
    
    private func addTracksFromLinks(_ links: [Manifest.Link]) {
        for (index, link) in links.enumerated() {
            if let track = createTrack(from: link, index: index) {
                tracks.append(track)
            }
        }
    }
    
    private func createTrack(from item: Manifest.ReadingOrderItem, index: Int) -> Track? {
        let title = item.title ?? "Untitled"
        let duration = item.duration
        
        if let part = item.findawayPart, let sequence = item.findawaySequence {
            return Track(type: .findaway(part: part, sequence: sequence), title: title, duration: duration, index: index)
        } else if let href = item.href {
            return Track(type: .href(href), title: title, duration: duration, index: index)
        }
        
        return nil
    }

    private func createTrack(from link: Manifest.Link, index: Int) -> Track? {
        let title = link.title ?? "Untitled"
        let bitrate = 64 * 1024
        var duration: Double
        
        if let explicitDuration = link.duration {
            duration = Double(explicitDuration)
        } else if let fileSizeInBytes = link.physicalFileLengthInBytes {
            let fileSizeInBits = fileSizeInBytes * 8
            duration = Double(fileSizeInBits / bitrate)
        } else {
            duration = 0
        }

        return Track(type: .href(link.href), title: title, duration: duration, index: index)
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
