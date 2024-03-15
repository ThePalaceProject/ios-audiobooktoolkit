//
//  TableOfContents.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Work on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

protocol TableOfContentsSource {
    var manifest: Manifest { get }
    var tracks: Tracks { get }
    var toc: [Chapter] { get }
}


struct TableOfContents: TableOfContentsSource {
    var manifest: Manifest
    var tracks: Tracks
    var toc: [Chapter]

    init(manifest: Manifest, tracks: Tracks) {
        self.manifest = manifest
        self.tracks = tracks
        self.toc = manifest.toc?.compactMap { entry -> Chapter? in
            guard let track = tracks.byHref(entry.href) else {
                    return nil
            }

            let offset = Int(entry.href.replacingOccurrences(of: "t=", with: "")) ?? 0

            return Chapter(title: entry.title ?? "", position: TrackPosition(track: track, timeStamp: offset * 1000, tracks: tracks))
        } ?? []
        
        if let firstEntry = self.toc.first, firstEntry.position.timeStamp != 0 || firstEntry.position.track.index != 0 {
            let firstTrackPosition = TrackPosition(track: tracks[0], timeStamp: 0, tracks: tracks)
            self.toc.insert(Chapter(title: "Forward", position: firstTrackPosition), at: 0)
        }
        
        self.calculateDurations()
    }
    
    mutating func calculateDurations() {
        for idx in toc.indices {
            let nextTocPosition = idx + 1 < toc.count ? toc[idx + 1].position :
            TrackPosition(
                track: tracks[tracks.count - 1],
                timeStamp: tracks[tracks.count - 1].duration,
                tracks: tracks
            )
            toc[idx].duration = nextTocPosition - toc[idx].position
        }
    }

    subscript(index: Int) -> Chapter {
        return toc[index]
    }
    
    var count: Int {
        return toc.count
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
            if position.track == chapter.position.track && position.timeStamp >= chapter.position.timeStamp &&
                position.timeStamp < chapter.position.timeStamp + (chapter.duration ?? 0) {
                return chapter
            }
        }
        throw ChapterError.noChapterFoundForPosition
    }
    
    func index(of chapter: Chapter) -> Int? {
        return toc.firstIndex(where: { $0.title == chapter.title })
    }
}

enum ChapterError: Error {
    case noChapterFoundForPosition
}

