//
//  TableOfContents.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Combine
import Foundation

// MARK: - AudiobookTableOfContentsProtocol

protocol AudiobookTableOfContentsProtocol {
  var manifest: Manifest { get }
  var tracks: Tracks { get }
  var toc: [Chapter] { get }
  func track(forKey key: String) -> (any Track)?
}

// MARK: - AudiobookTableOfContents

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
    toc = []

    if let spine = manifest.spine, !spine.isEmpty {
      loadTocFromSpine(spine)
    } else if let tocItems = manifest.toc, !tocItems.isEmpty {
      loadTocFromTocItems(tocItems)
    } else if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
      loadTocFromReadingOrder(readingOrder)
    } else if let linksDictionary = manifest.linksDictionary {
      loadTocFromLinks(linksDictionary)
    }

    if manifest.audiobookType != .findaway && manifest.audiobookType != .overdrive {
      calculateDurations()
      calculateEndPositions()
    }
    
    // DEBUG: Dump full TOC structure for debugging
    ATLog(.debug, "AudiobookTableOfContents initialized with \(toc.count) chapters and \(tracks.count) tracks")
    for (index, chapter) in toc.enumerated() {
      ATLog(.debug, "  Chapter[\(index)]: '\(chapter.title)' - track=\(chapter.position.track.title ?? "nil") (key=\(chapter.position.track.key)), timestamp=\(chapter.position.timestamp), duration=\(chapter.duration ?? -1)")
    }
    ATLog(.debug, "Tracks:")
    for (index, track) in tracks.tracks.enumerated() {
      ATLog(.debug, "  Track[\(index)]: '\(track.title ?? "nil")' (key=\(track.key)), duration=\(track.duration)")
    }
  }

  func track(forKey key: String) -> (any Track)? {
    tracks.track(forKey: key)
  }

  private mutating func loadTocFromTocItems(_ tocItems: [TOCItem]) {
    func appendChaptersRecursively(from items: [TOCItem]) {
      for item in items {
        if let chapter = parseChapter(from: item, tracks: tracks) {
          toc.append(chapter)
        }

        if let children = item.children, !children.isEmpty {
          appendChaptersRecursively(from: children)
        }
      }
    }

    appendChaptersRecursively(from: tocItems)
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
    return Chapter(title: tocItem.title ?? "Track \(validTrack.index + 1)", position: startPosition)
  }

  private mutating func loadTocFromReadingOrder(_ readingOrder: [Manifest.ReadingOrderItem]) {
    readingOrder.forEach { item in
      var track: (any Track)?
      var duration = 0.0

      if let href = item.href {
        track = tracks.track(forHref: href)
      } else if let part = item.findawayPart, let sequence = item.findawaySequence {
        track = tracks.track(forPart: part, sequence: sequence)
        duration = item.duration
      }

      if let validTrack = track {
        let chapterTitle = item.title ?? "Track \(validTrack.index + 1)"
        let chapter = Chapter(
          title: chapterTitle,
          position: TrackPosition(track: validTrack, timestamp: 0.0, tracks: tracks),
          duration: duration
        )
        toc.append(chapter)
      }
    }

    prependForwardChapterIfNeeded()
  }

  private mutating func loadTocFromLinks(_ links: Manifest.LinksDictionary) {
    links.contentLinks?.forEach { item in
      if let track = tracks.track(forHref: item.href) {
        let chapter = Chapter(
          title: item.title?.localizedTitle() ?? "Track \(track.index + 1)",
          position: TrackPosition(track: track, timestamp: 0.0, tracks: tracks)
        )
        toc.append(chapter)
      }
    }
  }

  private mutating func loadTocFromSpine(_ spine: [Manifest.SpineItem]) {
    spine.forEach { item in
      if let track = tracks.track(forHref: item.href) {
        let chapterTitle = item.title ?? "Track \(track.index + 1)"
        let chapter = Chapter(
          title: chapterTitle,
          position: TrackPosition(track: track, timestamp: 0.0, tracks: tracks)
        )
        toc.append(chapter)
      }
    }
  }

  private mutating func prependForwardChapterIfNeeded() {
    if let firstEntry = toc.first {
      if firstEntry.position.timestamp != 0 || firstEntry.position.track.index != 0 {
        let firstTrackPosition = TrackPosition(track: tracks[0], timestamp: 0.0, tracks: tracks)
        toc.insert(Chapter(title: "Forward", position: firstTrackPosition), at: 0)
      }
    }
  }

  private mutating func calculateDurations() {
    for (index, chapter) in toc.enumerated() {
      if index + 1 < toc.count {
        let nextChapter = toc[index + 1]
        toc[index].duration = try? nextChapter.position - chapter.position
      } else {
        toc[index].duration = calculateRemainingDuration(from: chapter.position)
      }
    }
  }

  private mutating func calculateEndPositions() {
    for index in toc.indices {
      toc[index].calculateEndPosition(using: tracks)
    }
  }

  private func calculateRemainingDuration(from start: TrackPosition) -> Double {
    var totalDuration = start.track.duration - start.timestamp

    if let startTrackIndex = tracks.tracks.firstIndex(where: { $0.id == start.track.id }) {
      for index in (startTrackIndex + 1)..<tracks.tracks.count {
        totalDuration += tracks[index].duration
      }
    }

    return totalDuration
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
    ATLog(.warn, "📚 chapter(forPosition:) called: track=\(position.track.key), timestamp=\(position.timestamp)")
    
    for (index, chapter) in toc.enumerated() {
      let chapterStart = chapter.position
      let chapterDuration = chapter.duration ?? chapter.position.track.duration

      let chapterEndPosition: TrackPosition
      if let endPos = chapter.endPosition {
        chapterEndPosition = endPos
      } else {
        if index + 1 < toc.count {
          let nextChapter = toc[index + 1]
          chapterEndPosition = nextChapter.position
        } else {
          chapterEndPosition = chapter.position + chapterDuration
        }
      }

      let isAfterStart = position >= chapterStart
      let isBeforeEnd = position < chapterEndPosition
      // Check if position is exactly at THIS chapter's end (not just any track end)
      // This handles the case where position is at exact chapter boundary
      let isAtChapterEnd = (position.track.key == chapterEndPosition.track.key && 
                            abs(position.timestamp - chapterEndPosition.timestamp) < 0.5)
<<<<<<< HEAD

      // Match if within chapter bounds OR if exactly at this chapter's end boundary
      if isAfterStart && (isBeforeEnd || isAtChapterEnd) {
=======
      
      ATLog(.warn, "📚   Checking '\(chapter.title)': start=(\(chapterStart.track.key), \(chapterStart.timestamp)), end=(\(chapterEndPosition.track.key), \(chapterEndPosition.timestamp)), isAfterStart=\(isAfterStart), isBeforeEnd=\(isBeforeEnd), isAtChapterEnd=\(isAtChapterEnd)")

      // Match if within chapter bounds OR if exactly at this chapter's end boundary
      if isAfterStart && (isBeforeEnd || isAtChapterEnd) {
        ATLog(.warn, "📚   ✅ MATCHED: '\(chapter.title)'")
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
        return chapter
      }
    }

<<<<<<< HEAD
    // Fallback: find closest chapter by position distance
=======
    ATLog(.warn, "chapter(forPosition:) - No direct match found, using fallback closest algorithm")
    
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
    let closestChapter = toc.min { chapter1, chapter2 in
      let dist1 = abs((try? position - chapter1.position) ?? Double.greatestFiniteMagnitude)
      let dist2 = abs((try? position - chapter2.position) ?? Double.greatestFiniteMagnitude)
      return dist1 < dist2
    }

    if let closest = closestChapter {
      ATLog(.warn, "  ⚠️ Fallback returned: '\(closest.title)' (this may indicate a bug)")
      return closest
    }
    throw ChapterError.noChapterFoundForPosition
  }

  public func chapterOffset(for position: TrackPosition) throws -> Double {
    let chapter = try chapter(forPosition: position)
    let chapterStartPosition = TrackPosition(
      track: chapter.position.track,
      timestamp: chapter.position.timestamp,
      tracks: position.tracks
    )

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

      var totalProgress = 0.0
      var totalDuration = 0.0

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

// MARK: - ChapterError

enum ChapterError: Error {
  case noChapterFoundForPosition
  case invalidChapterDuration
}

public extension AudiobookTableOfContents {
  var allTracks: [any Track] {
    tracks.tracks
  }
}
