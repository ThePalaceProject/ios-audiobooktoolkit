//
//  ChapterLocation.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 5/29/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

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
        max(self.duration - self.actualOffset, 0.0)
    }

    public var secondsBeforeStart: TimeInterval? {
        var timeInterval: TimeInterval? = nil
        if let chapterOffset = chapterOffset, self.playheadOffset < chapterOffset {
            timeInterval = chapterOffset - self.playheadOffset
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
    
    public func isSimilar(to location: ChapterLocation?) -> Bool {
        guard let location = location else { return false }
        return self.type == location.type &&
        self.number == location.number &&
        self.part == location.part &&
        self.chapterOffset == location.chapterOffset &&
        self.playheadOffset == location.playheadOffset &&
        self.title == location.title &&
        self.audiobookID == location.audiobookID &&
        self.duration == location.duration
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
    
    public init(number: UInt, part: UInt, duration: TimeInterval, startOffset: TimeInterval?, playheadOffset: TimeInterval, title: String?, audiobookID: String, lastSavedTimeStamp: String = "", annotationId: String = "") {
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

extension ChapterLocation: NSCopying {
    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = ChapterLocation(
            number: number,
            part: part,
            duration: duration,
            startOffset: chapterOffset,
            playheadOffset: playheadOffset,
            title: title,
            audiobookID: audiobookID
        )
        copy.lastSavedTimeStamp = self.lastSavedTimeStamp
        copy.annotationId = self.annotationId
        return copy
    }
}
