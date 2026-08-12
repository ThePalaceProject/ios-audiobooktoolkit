//
//  FindawayTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/29/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - FindawayTrackFactory

public class FindawayTrackFactory: NSObject, TrackFactoryProtocol {
  public static func createTrack(
    from manifest: PalaceAudiobookToolkit.Manifest,
    title: String?,
    urlString _: String?,
    audiobookID: String,
    index: Int,
    duration: Double,
    token _: String? = nil,
    key _: String? = nil
  ) -> (any PalaceAudiobookToolkit.Track)? {
    do {
      return try FindawayTrack(
        manifest: manifest,
        audiobookID: audiobookID,
        title: title,
        duration: duration,
        index: index
      )
    } catch {
      return nil
    }
  }
}

// MARK: - `FindawayTrack`

public final class FindawayTrack: Track {
  enum InitializationError: Error {
    case missingPartOrSequenceInfo
    case missingSessionKeyOrLicenseID
  }

  public let downloadTask: (any DownloadTask)?
  public let title: String?
  public let index: Int
  public let duration: TimeInterval
  public let partNumber: Int?
  public let chapterNumber: Int?
  /// Always `nil`: Findaway content is fetched through the AudioEngine SDK by
  /// (audiobookID, part, chapter) rather than by URL. This was previously an
  /// unassigned `var` relying on the implicit `nil` default; as a `let` the
  /// absence has to be stated, which is the point.
  public let urls: [URL]? = nil
  public let mediaType: TrackMediaType

  public let sessionKey: String
  public let licenseID: String
  public let audiobookID: String
  public let key: String

  public required init(
    manifest: PalaceAudiobookToolkit.Manifest,
    urlString _: String? = nil,
    audiobookID: String,
    title: String? = nil,
    duration: Double,
    index: Int,
    token _: String? = nil,
    key _: String? = nil
  ) throws {
    guard let partNumber = manifest.readingOrder?[index].findawayPart,
          let sequence = manifest.readingOrder?[index].findawaySequence
    else {
      throw InitializationError.missingPartOrSequenceInfo
    }

    guard let sessionKey = manifest.metadata?.drmInformation?.sessionKey,
          let licenseID = manifest.metadata?.drmInformation?.licenseID
    else {
      throw InitializationError.missingSessionKeyOrLicenseID
    }

    let fullfillmentID = manifest.metadata?.drmInformation?.fulfillmentId ?? audiobookID

    key = "urn:org.thepalaceproject:findaway:\(String(describing: partNumber)):\(String(describing: sequence))"
    self.index = index
    self.title = title
    self.duration = duration
    mediaType = manifest.trackMediaType
    self.audiobookID = fullfillmentID
    self.sessionKey = sessionKey
    self.licenseID = licenseID
    chapterNumber = sequence
    self.partNumber = partNumber
    downloadTask = FindawayDownloadTask(
      audiobookID: fullfillmentID,
      chapterNumber: UInt(sequence),
      partNumber: UInt(partNumber),
      sessionKey: sessionKey,
      licenseID: licenseID
    )
  }
}
