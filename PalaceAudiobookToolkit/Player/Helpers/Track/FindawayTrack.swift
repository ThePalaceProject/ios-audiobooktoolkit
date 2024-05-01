//
//  FindawayTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/29/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public class FindawayTrack: Track {
    enum InitializationError: Error {
        case missingPartOrSequenceInfo, missingSessionKeyOrLicenseID
    }
    
    public var key: String { "FAEAudioEngine-\(audiobookID)-\(chapterNumber)-\(partNumber)" }

    public var downloadTask: (any DownloadTask)?
    public var title: String?
    public var index: Int
    public var duration: TimeInterval
    public var partNumber: Int
    public var chapterNumber: Int
    public var urls: [URL]?
    public let mediaType: TrackMediaType
    
    public  var sessionKey: String
    public var licenseID: String
    public var audiobookID: String

    public init(
        manifest: Manifest,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int
    ) throws {
        guard let partNumber = manifest.readingOrder?.first(where: { $0.findawayPart != nil })?.findawayPart,
              let sequence = manifest.readingOrder?.first(where: { $0.findawayPart != nil })?.findawaySequence else {
            throw InitializationError.missingPartOrSequenceInfo
        }
        
        guard let sessionKey = manifest.metadata?.drmInformation?.sessionKey,
              let licenseID = manifest.metadata?.drmInformation?.licenseID else {
            throw InitializationError.missingSessionKeyOrLicenseID
        }
        
        self.index = index
        self.title = title
        self.duration = duration
        self.mediaType = manifest.trackMediaType
        self.audiobookID = audiobookID
        self.sessionKey = sessionKey
        self.licenseID = licenseID
        self.chapterNumber = sequence
        self.partNumber = partNumber
        self.downloadTask = FindawayDownloadTask(
            audiobookID: audiobookID,
            chapterNumber: UInt(sequence),
            partNumber: UInt(partNumber),
            sessionKey: sessionKey,
            licenseID: licenseID
        )
    }
}
