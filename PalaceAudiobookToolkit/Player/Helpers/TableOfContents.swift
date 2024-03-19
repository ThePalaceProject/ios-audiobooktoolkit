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

struct TableOfContents: TableOfContentsProtocol {
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

        self.loadToc()
        self.calculateDurations()
    }

    private mutating func loadToc() {
        let flatChapters = manifest.toc?.flatMap { entry -> [Chapter] in
            return flattenChapters(entry: entry, tracks: tracks)
        } ?? []
        
        self.toc = flatChapters
        
        if let firstEntry = self.toc.first,
           firstEntry.position.timestamp != 0 || firstEntry.position.track.index != 0
        {
            let firstTrackPosition = TrackPosition(track: tracks[0], timestamp: 0, tracks: tracks)
            self.toc.insert(Chapter(title: "Forward", position: firstTrackPosition), at: 0)
        }
    }

    private func flattenChapters(entry: TOCItem, tracks: Tracks) -> [Chapter] {
        var chapters: [Chapter] = []
        if let track = tracks.byHref(entry.href) {
            let offset = Int(entry.href.replacingOccurrences(of: "t=", with: "")) ?? 0
            let chapter = Chapter(title: entry.title ?? "", position: TrackPosition(track: track, timestamp: offset * 1000, tracks: tracks))
            chapters.append(chapter)
        }
        
        // Recursively flatten any nested children into the same list
        entry.children?.forEach { childEntry in
            chapters.append(contentsOf: flattenChapters(entry: childEntry, tracks: tracks))
        }
        
        return chapters
    }
    
    mutating func calculateDurations() {
        for idx in toc.indices {
            let nextTocPosition = idx + 1 < toc.count ? toc[idx + 1].position :
            TrackPosition(
                track: tracks[tracks.count - 1],
                timestamp: tracks[tracks.count - 1].duration,
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

