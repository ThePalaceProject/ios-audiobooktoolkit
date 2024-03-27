//
//  TableOfContents.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

protocol TableOfContentsProtocol {
    var manifest: Manifest { get }
    var tracks: Tracks { get }
    var toc: [Chapter] { get }
}

public struct TableOfContents: TableOfContentsProtocol {
    var manifest: Manifest
    var tracks: Tracks
    var toc: [Chapter]
    
    var count: Int {
        toc.count
    }
    
    init(manifest: Manifest, tracks: Tracks) {
        self.manifest = manifest
        self.tracks = tracks
        self.toc = []
        
        if let tocItems = manifest.toc, !tocItems.isEmpty {
            loadTocFromTocItems(tocItems)
        } else if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
            loadTocFromReadingOrder(readingOrder)
        } else if let linksDictionary = manifest.linksDictionary {
            loadTocFromLinks(linksDictionary)
        }
        
        self.calculateDurations()
    }
    
    private mutating func loadTocFromTocItems(_ tocItems: [TOCItem]) {
        tocItems.forEach { tocItem in
            toc.append(contentsOf: flattenChapters(entry: tocItem, tracks: tracks))
        }
        prependForwardChapterIfNeeded()
    }
    
    private mutating func loadTocFromReadingOrder(_ readingOrder: [Manifest.ReadingOrderItem]) {
        readingOrder.forEach { item in
            if let track = tracks.track(forHref: item.href ?? "") {
                let chapter = Chapter(title: item.title ?? "Untitled", position: TrackPosition(track: track, timestamp: 0, tracks: tracks))
                toc.append(chapter)
            }
        }
        prependForwardChapterIfNeeded()
    }

    private mutating func loadTocFromLinks(_ links: Manifest.LinksDictionary) {
        links.contentLinks?.forEach { item in
            if let track = tracks.track(forHref: item.href ?? "") {
                let chapter = Chapter(title: item.title ?? "Untitled", position: TrackPosition(track: track, timestamp: 0, tracks: tracks))
                toc.append(chapter)
            }
        }
    }
    
    private mutating func prependForwardChapterIfNeeded() {
        if let firstEntry = toc.first,
           firstEntry.position.timestamp != 0 || firstEntry.position.track.index != 0 {
            let firstTrackPosition = TrackPosition(track: tracks[0], timestamp: 0, tracks: tracks)
            toc.insert(Chapter(title: "Forward", position: firstTrackPosition), at: 0)
        }
    }

    private func flattenChapters(entry: TOCItem, tracks: Tracks) -> [Chapter] {
        guard let fullHref = entry.href else { return [] }
        var chapters: [Chapter] = []
        
        let components = fullHref.components(separatedBy: "#")
        let hrefWithoutFragment = components.first ?? ""
        
        let timestampString = components.last?.replacingOccurrences(of: "t=", with: "")
        let offsetInSeconds = Int(timestampString ?? "") ?? 0
        
        let offsetInMilliseconds = offsetInSeconds * 1000
        
        if let track = tracks.track(forHref: hrefWithoutFragment) {
            let chapter = Chapter(title: entry.title ?? "", position: TrackPosition(track: track, timestamp: offsetInMilliseconds, tracks: tracks))
            chapters.append(chapter)
        }
        
        entry.children?.forEach { childEntry in
            chapters.append(contentsOf: flattenChapters(entry: childEntry, tracks: tracks))
        }
        
        return chapters
    }
    
    mutating func calculateDurations() {
        for idx in toc.indices {
            let nextTocPosition = idx + 1 < toc.count ? toc[idx + 1].position :
            TrackPosition(
                track: tracks[tracks.tracks.count - 1],
                timestamp: tracks[tracks.tracks.count - 1].duration,
                tracks: tracks
            )
            toc[idx].duration = try? nextTocPosition - toc[idx].position
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
            if position.track == chapter.position.track && position.timestamp >= chapter.position.timestamp &&
                position.timestamp < chapter.position.timestamp + (chapter.duration ?? 0) {
                return chapter
            }
        }
        throw ChapterError.noChapterFoundForPosition
    }

    func index(of chapter: Chapter) -> Int? {
        return toc.firstIndex(where: { $0.title == chapter.title })
    }

    subscript(index: Int) -> Chapter {
        return toc[index]
    }
}

enum ChapterError: Error {
    case noChapterFoundForPosition
}

