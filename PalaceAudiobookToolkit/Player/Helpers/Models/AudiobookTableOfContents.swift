//
//  TableOfContents.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import Combine

protocol AudiobookTableOfContentsProtocol {
    var manifest: Manifest { get }
    var tracks: Tracks { get }
    var toc: [Chapter] { get }
    func track(forKey key: String) -> (any Track)?
}

public struct AudiobookTableOfContents: AudiobookTableOfContentsProtocol {
    public var manifest: Manifest
    public var tracks: Tracks
    public var toc: [Chapter]
    
    var count: Int {
        toc.count
    }
    
    init(manifest: Manifest, tracks: Tracks) {
        self.manifest = manifest
        self.tracks = tracks
        self.toc = []
        
        if let spine = manifest.spine, !spine.isEmpty {
            loadTocFromSpine(spine)
        } else if let tocItems = manifest.toc, !tocItems.isEmpty {
            loadTocFromTocItems(tocItems)
        } else if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
            loadTocFromReadingOrder(readingOrder)
        } else if let linksDictionary = manifest.linksDictionary {
            loadTocFromLinks(linksDictionary)
        }
        
        if manifest.audiobookType != .findaway {
            self.calculateDurations()
        }
    }
    
    func track(forKey key: String) -> (any Track)? {
        tracks.track(forKey: key)
    }
    
    private mutating func loadTocFromTocItems(_ tocItems: [TOCItem]) {
        for tocItem in tocItems {
            if let chapter = parseChapter(from: tocItem, tracks: tracks) {
                toc.append(chapter)
            }
            tocItem.children?.forEach { childItem in
                if let subChapter = parseChapter(from: childItem, tracks: tracks) {
                    toc.append(subChapter)
                }
            }
        }
        prependForwardChapterIfNeeded()
    }
    
    private func parseChapter(from tocItem: TOCItem, tracks: Tracks) -> Chapter? {
        guard let fullHref = tocItem.href else {
            return nil
        }
        
        let components = fullHref.components(separatedBy: "#")
        let trackHref = components.first
        
        var offsetInSeconds = 0.0
        if components.count > 1, let timestampString = components.last?.replacingOccurrences(of: "t=", with: "") {
            offsetInSeconds = Double(timestampString) ?? 0.0
        }
        
        let track = tracks.track(forHref: trackHref ?? fullHref)
        
        guard let validTrack = track else {
            return nil
        }
        
        let startPosition = TrackPosition(track: validTrack, timestamp: offsetInSeconds, tracks: tracks)
        return Chapter(title: tocItem.title ?? "Untitled", position: startPosition)
    }
    
    
    private mutating func loadTocFromReadingOrder(_ readingOrder: [Manifest.ReadingOrderItem]) {
        readingOrder.forEach { item in
            var track: (any Track)? = nil
            var duration = 0.0
            
            if let href = item.href {
                track = tracks.track(forHref: href)
            } else if let part = item.findawayPart, let sequence = item.findawaySequence {
                track = tracks.track(forPart: part, sequence: sequence)
                duration = item.duration
            }
            
            if let validTrack = track {
                let chapterTitle = item.title ?? "Untitled"
                let chapter = Chapter(title: chapterTitle, position: TrackPosition(track: validTrack, timestamp: 0.0, tracks: tracks), duration: duration)
                toc.append(chapter)
            }
        }
        
        prependForwardChapterIfNeeded()
    }
    
    private mutating func loadTocFromLinks(_ links: Manifest.LinksDictionary) {
        links.contentLinks?.forEach { item in
            if let track = tracks.track(forHref: item.href) {
                let chapter = Chapter(
                    title: item.title?.localizedTitle() ?? "Untitled",
                    position: TrackPosition(track: track, timestamp: 0.0, tracks: tracks)
                )
                toc.append(chapter)
            }
        }
    }
    
    private mutating func loadTocFromSpine(_ spine: [Manifest.SpineItem]) {
        spine.forEach { item in
            if let track = tracks.track(forHref: item.href) {
                let chapterTitle = item.title
                let chapter = Chapter(title: chapterTitle, position: TrackPosition(track: track, timestamp: 0.0, tracks: tracks))
                toc.append(chapter)
            }
        }
    }
    
    private mutating func prependForwardChapterIfNeeded() {
        if let firstEntry = toc.first,
           firstEntry.position.timestamp != 0 || firstEntry.position.track.index != 0 {
            let firstTrackPosition = TrackPosition(track: tracks[0], timestamp: 0.0, tracks: tracks)
            toc.insert(Chapter(title: "Forward", position: firstTrackPosition), at: 0)
        }
    }
    
    private mutating func calculateDurations() {
        for (index, chapter) in toc.enumerated() {
            if index + 1 < toc.count {
                let nextChapter = toc[index + 1]
                toc[index].duration = try? nextChapter.position - chapter.position
            } else {
                // Last chapter in the list
                toc[index].duration = chapter.position.track.duration - chapter.position.timestamp
            }
        }
    }
    
    func nextChapter(after chapter: Chapter) -> Chapter? {
        guard let index = toc.firstIndex(where: { $0.title == chapter.title }), index + 1 < toc.count else {
            return nil
        }
        return toc[index + 1]
    }
    
    func previousChapter(before chapter: Chapter) -> Chapter? {
        guard let index = toc.firstIndex(where: { $0.title == chapter.title }), index - 1 >= 0 else {
            return nil
        }
        return toc[index - 1]
    }
    
    func chapter(forPosition position: TrackPosition) throws -> Chapter {
        for chapter in toc {
            let chapterDuration = chapter.duration ?? 0
            let chapterEndPosition = try chapter.position + chapterDuration
            
            // Check if the position is within the chapter's range
            if position >= chapter.position && position < chapterEndPosition {
                return chapter
            }
        }
        
        throw ChapterError.noChapterFoundForPosition
    }
    
    public func chapterOffset(for position: TrackPosition) throws -> Double {
        let chapter = try self.chapter(forPosition: position)
        let chapterStartPosition = TrackPosition(track: chapter.position.track, timestamp: chapter.position.timestamp, tracks: position.tracks)
        
        return try position - chapterStartPosition
    }
    
    public func downloadProgress(for chapter: Chapter) -> Double {
        switch manifest.audiobookType {
        case .findaway:
            return Double(chapter.position.track.downloadTask?.downloadProgress ?? 0.0)
        default:
            guard let chapterIndex = toc.firstIndex(where: { $0 == chapter }) else {
                return 0.0
            }
            
            let startTrack = chapter.position.track
            let endTrack: any Track
            if chapterIndex + 1 < toc.count {
                endTrack = toc[chapterIndex + 1].position.track
            } else {
                guard let lastTrack = tracks.tracks.last else {
                    return 0.0
                }
                endTrack = lastTrack
            }
            
            let startTrackIndex = startTrack.index
            let endTrackIndex = endTrack.index
            
            guard startTrackIndex <= endTrackIndex,
                  startTrackIndex >= 0, endTrackIndex < tracks.count
            else {
                return 0.0
            }
            
            var totalProgress: Double = 0.0
            var totalDuration: Double = 0.0
            
            for trackIndex in startTrackIndex...endTrackIndex {
                if let track = tracks[trackIndex] {
                    let trackDuration = track.duration
                    let trackProgress = Double(track.downloadProgress)
                    
                    totalProgress += trackProgress * trackDuration
                    totalDuration += trackDuration
                }
            }
            
            return totalDuration > 0 ? totalProgress / totalDuration : 0.0
        }
        
    }
    
    func areTracksEqual(_ lhs: any Track, _ rhs: any Track) -> Bool {
        lhs.key == rhs.key && lhs.index == rhs.index
    }
    
    func index(of chapter: Chapter) -> Int? {
        toc.firstIndex(where: { $0.title == chapter.title })
    }
    
    subscript(index: Int) -> Chapter {
        toc[index]
    }
}

enum ChapterError: Error {
    case noChapterFoundForPosition
    case invalidChapterDuration
}

public extension AudiobookTableOfContents {
    var allTracks: [any Track] {
        tracks.tracks
    }
}
