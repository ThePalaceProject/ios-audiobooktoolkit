//
//  Tracks.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public protocol TrackFactoryProtocol {
    static func createTrack(
        from manifest: Manifest,
        title: String?,
        urlString: String?,
        audiobookID: String,
        index: Int,
        duration: Double,
        token: String?
    ) -> (any Track)?
}

class TrackFactory: TrackFactoryProtocol {
    static func createTrack(
        from manifest: Manifest,
        title: String? = "Untitled",
        urlString: String? = nil,
        audiobookID: String,
        index: Int,
        duration: Double,
        token: String?
    ) -> (any Track)? {
        switch manifest.audiobookType {
        case .lcp:
            return try? LCPTrack(
                manifest: manifest,
                urlString: urlString,
                audiobookID: audiobookID,
                title: title,
                duration: duration,
                index: index,
                token: token

            )
        case .findaway:
            let factoryClassName = "NYPLAEToolkit.FindawayTrackFactory"
            guard let factoryClass = NSClassFromString(factoryClassName) as? TrackFactoryProtocol.Type else {
                print("Failed to find track factory class.")
                return nil
            }
            
            return factoryClass.createTrack(
                from: manifest,
                title: title,
                urlString: urlString,
                audiobookID: audiobookID,
                index: index,
                duration: duration,
                token: nil
            )
        default:
            return try? OpenAccessTrack(
                manifest: manifest,
                urlString: urlString ?? "",
                audiobookID: audiobookID,
                title: title,
                duration: duration,
                index: index,
                token: token
            )
        }
    }
}



public class Tracks {
    var manifest: Manifest
    public var audiobookID: String
    public var tracks: [any Track] = []
    public var totalDuration: Double = 0
    
    private var token: String?
    
    init(manifest: Manifest, audiobookID: String, token: String?) {
        self.manifest = manifest
        self.audiobookID = audiobookID
        self.token = token
        self.initializeTracks()
        self.calculateTotalDuration()
    }
    
    public subscript(index: Int) -> (any Track)? {
        guard index >= 0 && index < tracks.count else {
            return nil
        }
        return tracks[index]   
    }
    
    public var count: Int {
        tracks.count
    }
    
    public var first: (any Track)? {
        tracks.first
    }

    private func initializeTracks() {
        if let spine = manifest.spine, !spine.isEmpty {
            addTracksFromSpine(spine)
        } else if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
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
        TrackFactory.createTrack(
            from: manifest,
            title: item.title,
            urlString: item.href, 
            audiobookID: self.audiobookID,
            index: index,
            duration: item.duration,
            token: token
        )
    }

    private func createTrack(from link: Manifest.Link, index: Int) -> (any Track)? {
        let title = link.title?.localizedTitle() ?? "Untitled"
        let bitrate = (link.bitrate ?? 64) * 1024
        var duration: Double
        
        if let explicitDuration = link.duration {
            duration = Double(explicitDuration)
        } else if let fileSizeInBytes = link.physicalFileLengthInBytes {
            let fileSizeInBits = fileSizeInBytes * 8
            duration = Double(fileSizeInBits / bitrate)
        } else {
            duration = 0
        }
        
        return TrackFactory.createTrack(
            from: manifest,
            title: title,
            urlString: link.href,
            audiobookID: self.audiobookID,
            index: index,
            duration: duration,
            token: token
        )
    }

    public func track(forHref href: String) -> (any Track)? {
        return tracks.first(where: { track in
            if (track.urls?.first?.absoluteString ?? "") == href {
                return true
            }
            return false
        })
    }
    
    public func track(forKey key: String) -> (any Track)? {
        return tracks.first(where: { track in
            if track.key == key {
                return true
            }
            return false
        })
    }

    private func addTracksFromSpine(_ spine: [Manifest.SpineItem]) {
        for (index, item) in spine.enumerated() {
            if let track = createTrack(from: item, index: index) {
                tracks.append(track)
            }
        }
    }
    
    private func createTrack(from item: Manifest.SpineItem, index: Int) -> (any Track)? {
        return TrackFactory.createTrack(
            from: manifest,
            title: item.title,
            urlString: item.href,
            audiobookID: audiobookID,
            index: index,
            duration: Double(item.duration),
            token: token
        )
    }

    public func track(forPart part: Int, sequence: Int) -> (any Track)? {
        return tracks.first(where: { track in
            return track.partNumber == part && track.chapterNumber == sequence
        })
    }

    public func previousTrack(_ track: any Track) -> (any Track)? {
        guard let currentIndex = tracks.first(where: { $0.id == track.id
        })?.index, currentIndex > 0 else {
            return nil
        }
        return tracks[currentIndex - 1]
    }
    
    public func nextTrack(_ track: any Track) -> (any Track)? {
        guard let currentIndex = tracks.first(where: { $0.id == track.id
        })?.index, currentIndex < tracks.count - 1 else {
            return nil
        }
        return tracks[currentIndex + 1]
    }
    
    public subscript(index: Int) -> any Track {
        return tracks[index]
    }
    
    public func deleteTracks() {
        tracks.forEach { track in
            track.downloadTask?.delete()
        }
    }
    
    private func calculateTotalDuration() {
        self.totalDuration = tracks.reduce(0) { $0 + $1.duration }
    }
}
