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
    private var audiobookID: String
    public var tracks: [any Track] = []
    public var totalDuration: Double = 0
    
    init(manifest: Manifest, audiobookID: String) {
        self.manifest = manifest
        self.audiobookID = audiobookID
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
    
    private func createTrack(from item: Manifest.ReadingOrderItem, index: Int) -> (any Track)? {
        let title = item.title ?? "Untitled"
        let duration = item.duration
        
        if let part = item.findawayPart,
           let sequence = item.findawaySequence {
            //TODO: Create Findaway track
            return nil
        } else if let href = item.href {
            switch manifest.audiobookType {
            case .lcp:
                return try? LCPTrack(
                    manifest: manifest,
                    urlString: href,
                    audiobookID: audiobookID,
                    title: title,
                    duration: duration,
                    index: index
                )
            default:
                return  try? OpenAccessTrack(
                    manifest: manifest,
                    urlString: href,
                    audiobookID: audiobookID,
                    title: title,
                    duration: duration,
                    index: index
                )
            }
        }

        return nil
    }

    private func createTrack(from link: Manifest.Link, index: Int) -> (any Track)? {
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
        
        switch manifest.audiobookType {
        case .lcp:
            return try? LCPTrack(manifest: manifest, urlString: link.href, audiobookID: audiobookID, title: title, duration: duration, index: index)
        default:
            return  try? OpenAccessTrack(manifest: manifest, urlString: link.href, audiobookID: audiobookID, title: title, duration: duration, index: index)
        }
//        return try? OpenAccessTrack(manifest: manifest, urlString: link.href, audiobookID: audiobookID, title: title, duration: duration, index: index)
    }


    func track(forHref href: String) -> (any Track)? {
        return tracks.first(where: { track in
            if (track.urls?.first?.absoluteString ?? "") == href {
                return true
            }
            return false
        })
    }
    
    func track(forKey key: String) -> (any Track)? {
        return tracks.first(where: { track in
            if track.key == key {
                return true
            }
            return false
        })
    }
    
    func track(forPart part: Int, sequence: Int) -> (any Track)? {
        //TODO: Implement for Findaway
//        return tracks.first(where: { track in
//            if let track as? FindawayTrack,
//               trackPart == part && trackSequence == sequence {
//                return true
//            }
//            
//            return false
//        })
        return nil
    }
    
    func previousTrack(_ track: any Track) -> (any Track)? {
        guard let currentIndex = tracks.first(where: { $0.id == track.id
        })?.index, currentIndex > 0 else {
            return nil
        }
        return tracks[currentIndex - 1]
    }
    
    func nextTrack(_ track: any Track) -> (any Track)? {
        guard let currentIndex = tracks.first(where: { $0.id == track.id
        })?.index, currentIndex < tracks.count - 1 else {
            return nil
        }
        return tracks[currentIndex + 1]
    }
    
    subscript(index: Int) -> any Track {
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
