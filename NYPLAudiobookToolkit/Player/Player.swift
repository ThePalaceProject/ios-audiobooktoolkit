import Foundation

@objc public enum PlaybackRate: Int, CaseIterable {
    case threeQuartersTime = 75
    case normalTime = 100
    case oneAndAQuarterTime = 125
    case oneAndAHalfTime = 150
    case doubleTime = 200
    
    public static func convert(rate: PlaybackRate) -> Float {
        return Float(rate.rawValue) * 0.01
    }
}

/// Receive updates from player as events happen
@objc public protocol PlayerDelegate: class {

    /// Guaranteed to be called on the following scenarios:
    ///   * The playhead crossed to a new chapter
    ///   * The play() method was called
    ///   * The playhead was modified, the result of jumpToLocation(_), skipForward() or skipBack()
    func player(_ player: Player, didBeginPlaybackOf chapter: ChapterLocation)

    /// Called to notify that playback has stopped
    /// this should only happen as a result of pause() being called.
    func player(_ player: Player, didStopPlaybackOf chapter: ChapterLocation)

    /// Playback failed. Send an error with more context if it is available.
    func player(_ player: Player, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?)

    /// Called when the playhead crosses a chapter boundary without direction.
    /// Depending on the underlying playback engine, this could come some time
    /// after the next chapter has begun playing. This should arrive before
    /// `player:didBeginPlaybackOf:` is called.
    func player(_ player: Player, didComplete chapter: ChapterLocation)

    /// Called by the host when we're done with the audiobook, to perform necessary cleanup.
    func playerDidUnload(_ player: Player)
}

/// Objects that impelment Player should wrap a PlaybackEngine.
/// This does not specifically refer to AVPlayer, but could also be
/// FAEPlaybackEngine, or another engine that handles DRM content.
@objc public protocol Player {
    typealias Completion = (Error?) -> Void

    var isPlaying: Bool { get }
    // Player maintains an internal queue
    var queuesEvents: Bool { get }
    // When set, should lock down playback
    var isDrmOk: Bool { get set }
    
    var currentChapterLocation: ChapterLocation? { get }

    /// The rate at which the audio will play, when playing.
    var playbackRate: PlaybackRate { get set }
    
    /// `false` after `unload` is called, else `true`.
    var isLoaded: Bool { get }
    
    /// Play at current playhead location
    func play()
    
    /// Pause playback
    func pause()
  
    /// End playback and free resources; the `Player` is not expected to be
    /// usable after this method is called
    func unload()
    
    /// Skip forward or backward with the desired interval in seconds,
    /// returns the actual time interval delivered to the Player.
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((ChapterLocation)->())?) -> ()

    /// Move playhead and immediately start playing
    /// This method is useful for scenarios like a table of contents
    /// where you select a new chapter and wish to immediately start
    /// playback.
    func playAtLocation(_ newLocation: ChapterLocation, completion: Completion?)

    /// Move playhead but do not start playback. This is useful for
    /// state restoration where we want to prepare for playback
    /// at a specific point, but playback has not yet been requested.
    func movePlayheadToLocation(_ location: ChapterLocation, completion: Completion?)

    func registerDelegate(_ delegate: PlayerDelegate)
    func removeDelegate(_ delegate: PlayerDelegate)
}

extension Player {
    func savePlaybackRate(rate: PlaybackRate) {
        UserDefaults.standard.set(rate.rawValue, forKey: "playback_rate")
    }

    func fetchPlaybackRate() -> PlaybackRate? {
        guard let rate = UserDefaults.standard.value(forKey: "playback_rate") as? Int else { return nil }
        return PlaybackRate(rawValue: rate)
    }
}

/// This class represents a location in a book.
@objcMembers public final class ChapterLocation: NSObject, Comparable, Codable {
    public let type: String? = "LocatorAudioBookTime"
    public let number: UInt
    public let part: UInt
    // Starting offset for current chapter in the event chapter does not begin at the start of the audio file
    public let chapterOffset: TimeInterval?
    // Actual offset of the playhead based on location in audio file
    public let playheadOffset: TimeInterval
    public let title: String?
    public let audiobookID: String
    public let duration: TimeInterval
    public var lastSavedTimeStamp: String = ""
    public var annotationId: String = ""

    public var actualOffset: TimeInterval {
        max(self.playheadOffset - (self.chapterOffset ?? 0), 0)
    }

    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case number = "chapter"
        case part
        case startOffset
        case playheadOffset = "time"
        case title
        case audiobookID
        case duration
        case annotationId
        case lastSavedTimeStamp
    }

    enum LegacyKeys: String, CodingKey {
        case type = "@type"
        case number
        case part
        case startOffset
        case playheadOffset
        case title
        case audiobookID
        case duration
        case lastSavedTimeStamp
    }

    public var timeRemaining: TimeInterval {
        self.duration - self.actualOffset
    }

    public var secondsBeforeStart: TimeInterval? {
        var timeInterval: TimeInterval? = nil
        if self.playheadOffset < self.chapterOffset ?? 0 {
            timeInterval = abs((self.chapterOffset ?? 0) - self.playheadOffset)
        }
        return timeInterval
    }
    
    public var timeIntoNextChapter: TimeInterval? {
        var timeInterval: TimeInterval? = nil
        if self.actualOffset > self.duration {
            timeInterval = self.actualOffset - self.duration
        }
        return timeInterval
    }
    
    public func inSameChapter(other: ChapterLocation?) -> Bool {
        guard let rhs = other else { return false }
        return self.audiobookID == rhs.audiobookID &&
            self.number == rhs.number &&
            self.part == rhs.part
    }
    
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        // Legacy bookmarks will not have a type property and need to be decoded
        // using legacy keys.
        guard values.contains(.type) else {
            let legacyValues = try decoder.container(keyedBy: LegacyKeys.self)
            audiobookID = try legacyValues.decode(String.self, forKey: .audiobookID)
            title = try legacyValues.decode(String.self, forKey: .title)
            number = try legacyValues.decode(UInt.self, forKey: .number)
            part = try legacyValues.decode(UInt.self, forKey: .part)
            duration = Double(try legacyValues.decode(Float.self, forKey: .duration))
            playheadOffset = Double(try legacyValues.decode(Float.self, forKey: .playheadOffset))
            chapterOffset = Double(try legacyValues.decode(Float.self, forKey: .startOffset))
            lastSavedTimeStamp = try legacyValues.decode(String.self, forKey: .lastSavedTimeStamp)
            return
        }

        audiobookID = try values.decode(String.self, forKey: .audiobookID)
        title = try values.decode(String.self, forKey: .title)
        number = try values.decode(UInt.self, forKey: .number)
        part = try values.decode(UInt.self, forKey: .part)
        duration = Double(try values.decode(Int.self, forKey: .duration)/1000)
        playheadOffset = Double(try values.decode(Int.self, forKey: .playheadOffset)/1000)
        chapterOffset = Double(try values.decode(Int.self, forKey: .startOffset)/1000)
        annotationId = try values.decode(String.self, forKey: .annotationId)
        lastSavedTimeStamp = try values.decode(String.self, forKey: .lastSavedTimeStamp)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(number, forKey: .number)
        try container.encode(part, forKey: .part)
        try container.encode(Int(duration.milliseconds), forKey: .duration)
        try container.encode(Int((chapterOffset ?? 0).milliseconds), forKey: .startOffset)
        try container.encode(Int(playheadOffset.milliseconds), forKey: .playheadOffset)
        try container.encode(type, forKey: .type)
        try container.encode(audiobookID, forKey: .audiobookID)
        try container.encode(annotationId, forKey: .annotationId)
        try container.encode(lastSavedTimeStamp, forKey: .lastSavedTimeStamp)
    }

    public init(number: UInt, part: UInt, duration: TimeInterval, startOffset: TimeInterval?, playheadOffset: TimeInterval, title: String?, audiobookID: String, lastSavedTimeStamp: String = Date().iso8601, annotationId: String = "") {
        self.audiobookID = audiobookID
        self.number = number
        self.part = part
        self.duration = duration
        self.chapterOffset = startOffset
        self.playheadOffset = playheadOffset
        self.title = title
        self.lastSavedTimeStamp = lastSavedTimeStamp
        self.annotationId = annotationId
    }

    public func update(playheadOffset offset: TimeInterval) -> ChapterLocation? {
        ChapterLocation(
            number: self.number,
            part: self.part,
            duration: self.duration,
            startOffset: self.chapterOffset,
            playheadOffset: offset,
            title: self.title,
            audiobookID: self.audiobookID,
            annotationId: annotationId
        )
    }

    public override var description: String {
        "ChapterLocation P \(self.part) CN \(self.number); PH \(self.playheadOffset) AO \(self.actualOffset) D \(self.duration)"
    }
    
    public func toData() -> Data {
        try! JSONEncoder().encode(self)
    }
    
    public class func fromData(_ data: Data) -> ChapterLocation? {
        try? JSONDecoder().decode(ChapterLocation.self, from: data)
    }

    public static func < (lhs: ChapterLocation, rhs: ChapterLocation) -> Bool {
        if lhs.part != rhs.part {
            return lhs.part < rhs.part
        } else if lhs.number != rhs.number {
            return lhs.number < rhs.number
        } else {
            return lhs.playheadOffset < rhs.playheadOffset
        }
    }
}

public typealias Playhead = (location: ChapterLocation, cursor: Cursor<SpineElement>)

/// Utility function for manipulating the playhead.
///
/// We navigate around audiobooks using `ChapterLocation` objects that represent
/// some section of audio that the player can navigate to.
///
/// We seek through chapters by calling the `chapterWith(_ offset:)` method on
/// the `currentChapterLocation` to create a new `ChapterLocation` with an
/// offset pointing to the passed in `offset`.
///
/// It is possible the new `offset` is not located in the `ChapterLocation` it
/// represents. For example, if the new `offset` is longer than the duration of
/// the chapter. The `moveTo(to:cursor:)` function resolves such conflicts and
/// returns a `Playhead` containing the correct chapter location for a Player to
/// use.
///
/// For example, if you have 5 seconds left in a chapter and you go to skip
/// ahead 15 seconds. This chapter will return a `Playhead` where the `location`
/// is 10 seconds into the next chapter and a `cursor` that points to the new
/// playhead.
///
/// - Parameters:
///   - destination: The `ChapterLocation` we are navigating to. This
///     destination has a playhead that may or may not be inside the chapter it
///     represents.
///   - cursor: The `Cursor` representing the spine for that book.
/// - Returns: The `Playhead` where the location represents the chapter the
///   playhead is located in, and a cursor that points to that chapter.
public func move(cursor: Cursor<SpineElement>, to destination: ChapterLocation) -> Playhead {

    // Check if location is in immediately adjacent chapters
    if let nextPlayhead = attemptToMove(cursor: cursor, forwardTo: destination) {
        return nextPlayhead
    } else if let prevPlayhead = attemptToMove(cursor: cursor, backTo: destination) {
        return prevPlayhead
    }

    // If not, locate the spine index containing the location
    var foundIndex: Int? = nil
    for (i, element) in cursor.data.enumerated() {

        if element.chapter.number == destination.number {
            foundIndex = i
            break
        }
    }
    if let foundIndex = foundIndex {
        return (destination, Cursor(data: cursor.data, index: foundIndex)!)
    } else {
        ATLog(.error, "Cursor move failure. Returning original cursor.")
        return (cursor.currentElement.chapter, cursor)
    }
}

/// For special UX consideration, many types of skips may not actually be
/// intended to move at the original requested duration.
///
/// - Parameters:
///   - currentOffset: Current playhead offset of the current spine element / chapter
///   - chapterDuration: Full duration of the spine element / chapter (end of scrubber)
///   - skipTime: The requested skip time interval
/// - Returns: The new Playhead Offset location that should be set
public func adjustedPlayheadOffset(currentPlayheadOffset currentOffset: TimeInterval,
                                   actualPlayheadOffset actualOffset: TimeInterval? = nil,
                                   currentChapterDuration chapterDuration: TimeInterval,
                                   requestedSkipDuration skipTime: TimeInterval) -> TimeInterval {
    let requestedPlayheadOffset = currentOffset + skipTime
    let actualPlayheadOffset = (actualOffset ?? currentOffset) + skipTime
    if (currentOffset == chapterDuration) {
        return requestedPlayheadOffset
    } else if (skipTime > 0) {
        if actualPlayheadOffset < chapterDuration {
            return requestedPlayheadOffset
        } else {
            return chapterDuration
        }
    } else  {
        if currentOffset > abs(skipTime) {
            return requestedPlayheadOffset
        } else {
            return skipTime
        }
    }
}

private func chapterAt(cursor: Cursor<SpineElement>) -> ChapterLocation {
    return cursor.currentElement.chapter
}

private func playhead(location: ChapterLocation?, cursor: Cursor<SpineElement>?) -> Playhead? {
    guard let location = location else { return nil }
    guard let cursor = cursor else { return nil }
    return (location: location, cursor: cursor)
}

private func attemptToMove(cursor: Cursor<SpineElement>, forwardTo location: ChapterLocation) -> Playhead? {

    // Same chapter, but playhead offset is beyond upper bound
    guard let timeIntoNextChapter = location.timeIntoNextChapter else { return nil }
    var possibleDestinationLocation: ChapterLocation?

    let newCursor: Cursor<SpineElement>
    if let (nextCursor, nextLocation) = findNextChapter(cursor: cursor, timeIntoNextChapter: timeIntoNextChapter) {
        possibleDestinationLocation = nextLocation
        newCursor = nextCursor
    } else {
        // No chapter exists after the current one
        possibleDestinationLocation = chapterAt(cursor: cursor).update(
            playheadOffset: chapterAt(cursor: cursor).duration
        )
        newCursor = cursor
    }
    return playhead(location: possibleDestinationLocation, cursor: newCursor)
}

private func findNextChapter(cursor: Cursor<SpineElement>, timeIntoNextChapter: TimeInterval) -> (Cursor<SpineElement>, ChapterLocation?)? {
    guard let newCursor = cursor.next() else { return nil }
    
    let destinationChapter = chapterAt(cursor: newCursor)
    guard destinationChapter.duration > timeIntoNextChapter else {
        let remainingTimeIntoNextChapter = timeIntoNextChapter - destinationChapter.duration
        return findNextChapter(cursor: newCursor, timeIntoNextChapter: remainingTimeIntoNextChapter)
    }

    return (newCursor, destinationChapter.update(playheadOffset: (destinationChapter.chapterOffset ?? destinationChapter.playheadOffset) + timeIntoNextChapter))
}

private func attemptToMove(cursor: Cursor<SpineElement>, backTo location: ChapterLocation) -> Playhead?  {

    // Same chapter, but playhead offset is below lower bound
    guard let timeIntoPreviousChapter = location.secondsBeforeStart else {
        debugPrint("No negative time detected.")
        return nil
    }
    var possibleDestinationLocation: ChapterLocation?

    let newCursor: Cursor<SpineElement>
    if let (previousCursor, destinationLocation) = findPreviousChapter(cursor: cursor, timeIntoPreviousChapter: timeIntoPreviousChapter) {
        newCursor = previousCursor
        possibleDestinationLocation = destinationLocation
    } else {
        // No chapter exists before the current one
        possibleDestinationLocation = chapterAt(cursor: cursor).update(playheadOffset: 0)
        newCursor = cursor
    }
    return playhead(location: possibleDestinationLocation, cursor: newCursor)
}

private func findPreviousChapter(cursor: Cursor<SpineElement>, timeIntoPreviousChapter: TimeInterval) -> (Cursor<SpineElement>, ChapterLocation?)? {
    guard let newCursor = cursor.prev() else { return nil }
    
    let destinationChapter = chapterAt(cursor: newCursor)
    let playheadOffset = (destinationChapter.chapterOffset ?? 0) + destinationChapter.duration - timeIntoPreviousChapter
    guard playheadOffset > 0 || destinationChapter.number == 0 else {
        return findPreviousChapter(cursor: newCursor, timeIntoPreviousChapter: abs(playheadOffset))
    }

    return (newCursor, destinationChapter.update(playheadOffset: max(0, playheadOffset)))
}


