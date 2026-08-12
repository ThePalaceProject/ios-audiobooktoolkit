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

    collapseAdjacentDuplicateKeyChapters()

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

  /// Repair chapter lists that don't match the physical audio files, so the
  /// toolkit's `toc` (used by currentChapter / NowPlaying / saved-position) is the
  /// SAME single list the UI shows. Two cases, one rule each:
  ///
  /// 1. Densely-subdivided TOC — many section/paragraph entries over few audio
  ///    files (e.g. "The Martian": 41 TOC entries, 8 files). Detected by the 1.5x
  ///    inflation threshold; collapsed to ONE chapter per physical `track.key`.
  ///    This is the app's historical `ChapterTOCNormalizer` collapse, MOVED here
  ///    so the toolkit and app share one implementation (no second list to drift).
  ///
  /// 2. Oversubdivided readingOrder — a manifest that repeats the same physical
  ///    `(part, sequence)` / `track.key` for several chapters that all start at the
  ///    SAME offset (Findaway "Dune", Findaway id 32884: 3 chapters all on
  ///    findaway:1:3 @ts0). Not dense enough to trip the threshold, but still one
  ///    playable file behind several @ts0 chapters → currentChapter / NowPlaying /
  ///    saved-position desync ("dual numbering"; a 30s skip never crosses a
  ///    non-existent intra-file boundary). Collapsed by dropping adjacent chapters
  ///    that repeat the previous chapter's (track.key, start offset).
  ///
  /// Both keep the FIRST chapter of a group unchanged (matching the app's display).
  /// Chapters that share a `track.key` but start at DISTINCT offsets — legitimate
  /// multi-chapter-per-file, e.g. open-access "Dungeon Crawler Carl" (Part I @t=1,
  /// Chapter 2 @t=3 in one MP3) — are PRESERVED: offset-distinctness is the
  /// separator, so real navigation is never lost.
  private mutating func collapseAdjacentDuplicateKeyChapters() {
    guard toc.count > 1 else { return }
    if Self.isOversubdivided(tocCount: toc.count, trackCount: tracks.tracks.count) {
      keepFirstChapterPerTrackKey()
    } else {
      collapseAdjacentDuplicatePositions()
    }
  }

  /// Dense-TOC collapse: keep one chapter per physical `track.key`.
  private mutating func keepFirstChapterPerTrackKey() {
    var seenKeys = Set<String>()
    var collapsed: [Chapter] = []
    collapsed.reserveCapacity(toc.count)
    for chapter in toc where seenKeys.insert(chapter.position.track.key).inserted {
      collapsed.append(chapter)
    }
    toc = collapsed
  }

  /// Findaway-oversubdivision collapse: drop adjacent chapters that repeat the
  /// previous chapter's (track.key, start offset). Distinct offsets are preserved.
  private mutating func collapseAdjacentDuplicatePositions() {
    let epsilon = 0.5
    var collapsed: [Chapter] = []
    collapsed.reserveCapacity(toc.count)
    for chapter in toc {
      if let last = collapsed.last,
         last.position.track.key == chapter.position.track.key,
         abs(last.position.timestamp - chapter.position.timestamp) < epsilon {
        continue
      }
      collapsed.append(chapter)
    }
    toc = collapsed
  }

  /// TOC oversubdivision threshold: a flat TOC with more than `trackCount * 1.5`
  /// entries is densely subdivided into sections rather than chapters. Mirrors the
  /// app's historical `ChapterTOCNormalizer.isOversubdivided` so the dense-collapse
  /// behavior is identical when it moves into the toolkit (single source of truth).
  static func isOversubdivided(tocCount: Int, trackCount: Int) -> Bool {
    guard trackCount > 0 else { return false }
    return Double(tocCount) > Double(trackCount) * 1.5
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
    guard let index = toc.firstIndex(where: { $0 == chapter }), index + 1 < toc.count else {
      return nil
    }
    return toc[index + 1]
  }

  func previousChapter(before chapter: Chapter) -> Chapter? {
    guard let index = toc.firstIndex(where: { $0 == chapter }), index - 1 >= 0 else {
      return nil
    }
    return toc[index - 1]
  }

  /// Returns the chapter containing `position`.
  ///
  /// Chapter ranges are half-open: a chapter owns `[start, end)`, and the
  /// position exactly on a boundary belongs to the chapter that BEGINS there,
  /// not the one that ends there. That is what "skip to the next chapter" means
  /// — the seek lands precisely on the boundary, and the patron expects to be
  /// in the chapter they skipped to.
  ///
  /// This used to be the other way round, and not only for the exact boundary.
  /// The end-of-chapter test was applied to every chapter with a 0.5s
  /// tolerance, and because `calculateEndPosition` sets each chapter's end to
  /// exactly the next chapter's start, the scan matched the PREVIOUS chapter
  /// first for anything within half a second of a boundary. So the first half
  /// second of every chapter was attributed to the chapter before it: Now
  /// Playing and CarPlay showed the title the patron had just left, with time
  /// remaining pinned at zero, and `chapterOffset` returned the previous
  /// chapter's full duration instead of ~0. `testPP3518_ChapterBoundaryOnSameTrack`
  /// pins both the boundary itself and the 0.5s window after it.
  ///
  /// The tolerance is still applied to the LAST chapter, which has no successor
  /// to hand the boundary to — there, a position at the very end of the book
  /// must still resolve to something.
  ///
  /// - Parameter preferChapterEndingHere: resolves a boundary position to the
  ///   chapter that ENDS there rather than the one that begins. This is the
  ///   pre-PP-4948 tie-break, retained for the resolution sites that feed the
  ///   `.completed(chapter)` playback signal.
  ///
  ///   **The full census, because getting it wrong twice is how this parameter
  ///   came to exist.** `.completed` is emitted from THREE places —
  ///   `OpenAccessPlayer.playerItemDidReachEnd`, and `FindawayPlayer`'s
  ///   `audioEnginePlaybackFinished` and `handlePlaybackEnd`.
  ///   `LCPStreamingPlayer` does not emit it: it resolves chapters only to
  ///   decide whether to continue in-place or delegate to `super`, which then
  ///   emits. That makes SIX resolution call sites feeding those three
  ///   emissions — two in `OpenAccessPlayer`, two in `LCPStreamingPlayer`, and
  ///   two in `FindawayPlayer` — and all six pass `true`.
  ///
  ///   Note the Findaway helper `chapter(for findawayChapter:)` also feeds
  ///   `.started` and `.stopped`, so those are held on the old tie-break as
  ///   well. That is deliberate: this parameter preserves the status quo
  ///   wholesale rather than selectively.
  ///
  ///   They ask "does the next track continue the same chapter?" by resolving
  ///   the ended track's end and the next track's start and comparing. Under the
  ///   old tie-break both sides resolved to the chapter ending at the boundary,
  ///   so the answer was always "yes" whenever a next track existed, and the
  ///   `.completed(chapter)` branch below them was reachable only at end of
  ///   book. Flipping the tie-break makes that branch live at EVERY chapter
  ///   boundary — and `.completed` is not a display signal: it reaches
  ///   `AudiobookManager.handlePlaybackCompleted`, which calls
  ///   `saveLocation(chapter.position)` — the START of the chapter that just
  ///   finished — and the app's session manager sets `isPlaying = false` and
  ///   `.paused`. So the boundary correction would pause playback at every
  ///   chapter and rewind the saved position by a whole chapter.
  ///
  ///   Whether `.completed` SHOULD fire per chapter is a real question, and the
  ///   answer differs by playback path — a distinction an earlier version of
  ///   this comment flattened, wrongly:
  ///
  ///   * On the **AVPlayer paths** (open-access, LCP streaming) it never fires
  ///     mid-book, because the same-chapter check above always says "continue"
  ///     while a next track exists.
  ///   * On **Findaway** it fires at EVERY chapter and always has, driven by the
  ///     audio engine's per-chapter `FAEPlaybackChapterComplete` notification
  ///     (`FAEPlaybackAudiobookComplete` is the separate end-of-book event). So
  ///     the flip would not change WHETHER it fires there — only which chapter
  ///     it names.
  ///
  ///   With the old tie-break a completed Findaway chapter resolves to the one
  ///   BEFORE it (measured in review: 9 of 10 chapters on a real title), so
  ///   `handlePlaybackCompleted` saves that earlier chapter's start. This pin
  ///   preserves that rather than causing it.
  ///
  ///   - Warning: flipping this parameter does not fix that, and assuming it
  ///     does is the trap. `handlePlaybackCompleted` saves `chapter.position`,
  ///     the chapter's START, so the save moves from "start of N−1" to "start
  ///     of N" — still behind the real listening position. The rest depends on
  ///     a separate periodic save and on what the app does with `.completed`,
  ///     neither of which this parameter reaches. The full picture, including
  ///     what has and has not been measured, is `docs/followups.md` item 21;
  ///     the decision is PP-4951. Do not act on this comment alone.

  func chapter(
    forPosition position: TrackPosition,
    preferChapterEndingHere: Bool = false
  ) throws -> Chapter {
    for (index, chapter) in toc.enumerated() {
      let chapterStart = chapter.position
      let chapterDuration = chapter.duration ?? chapter.position.track.duration
      let isLastChapter = index + 1 >= toc.count

      let chapterEndPosition: TrackPosition
      if let endPos = chapter.endPosition {
        chapterEndPosition = endPos
      } else {
        if !isLastChapter {
          let nextChapter = toc[index + 1]
          chapterEndPosition = nextChapter.position
        } else {
          chapterEndPosition = chapter.position + chapterDuration
        }
      }

      let isAfterStart = position >= chapterStart
      let isBeforeEnd = position < chapterEndPosition
      let isAtChapterEnd = (position.track.key == chapterEndPosition.track.key &&
                            abs(position.timestamp - chapterEndPosition.timestamp) < 0.5)

      if isAfterStart && (isBeforeEnd || ((isLastChapter || preferChapterEndingHere) && isAtChapterEnd)) {
        return chapter
      }
    }

    // Fallback: find closest chapter by position distance
    let closestChapter = toc.min { chapter1, chapter2 in
      let dist1 = abs((try? position - chapter1.position) ?? Double.greatestFiniteMagnitude)
      let dist2 = abs((try? position - chapter2.position) ?? Double.greatestFiniteMagnitude)
      return dist1 < dist2
    }

    if let closest = closestChapter {
      return closest
    }
    throw ChapterError.noChapterFoundForPosition
  }

  /// Returns the elapsed time within the current chapter for the given position.
  /// The result is always clamped to [0, chapterDuration] to prevent negative time remaining.
  public func chapterOffset(for position: TrackPosition) throws -> Double {
    let chapter = try chapter(forPosition: position)
    let chapterStartPosition = TrackPosition(
      track: chapter.position.track,
      timestamp: chapter.position.timestamp,
      tracks: position.tracks
    )

    let rawOffset = try position - chapterStartPosition
    let chapterDuration = chapter.duration ?? position.track.duration
    
    // Clamp to valid range: [0, chapterDuration]
    // This prevents negative time remaining in Now Playing displays
    let clampedOffset = max(0, min(rawOffset, chapterDuration))
    
    ATLog(.debug, "📊 chapterOffset: raw=\(rawOffset), duration=\(chapterDuration), clamped=\(clampedOffset)")
    
    return clampedOffset
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
    toc.firstIndex(where: { $0 == chapter })
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
