//
//  Tracks.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - TrackFactoryProtocol

public protocol TrackFactoryProtocol {
  static func createTrack(
    from manifest: Manifest,
    title: String?,
    urlString: String?,
    audiobookID: String,
    index: Int,
    duration: Double,
    token: String?,
    key: String?
  ) -> (any Track)?
}

// MARK: - TrackFactory

class TrackFactory: TrackFactoryProtocol {
  static func createTrack(
    from manifest: Manifest,
    title: String? = "",
    urlString: String? = nil,
    audiobookID: String,
    index: Int,
    duration: Double,
    token: String?,
    key: String?
  ) -> (any Track)? {
    switch manifest.audiobookType {
    case .findaway:
      try? FindawayTrack(
        manifest: manifest,
        urlString: urlString,
        audiobookID: audiobookID,
        title: title,
        duration: duration,
        index: index,
        token: token
      )
    case .lcp:
      try? LCPTrack(
        manifest: manifest,
        urlString: urlString,
        audiobookID: audiobookID,
        title: title,
        duration: duration,
        index: index,
        token: token,
        key: key
      )
    case .overdrive:
      try? OverdriveTrack(
        manifest: manifest,
        urlString: urlString,
        audiobookID: audiobookID,
        title: title,
        duration: duration,
        index: index,
        key: key
      )
    default:
      try? OpenAccessTrack(
        manifest: manifest,
        urlString: urlString ?? "",
        audiobookID: audiobookID,
        title: title,
        duration: duration,
        index: index,
        token: token,
        key: key
      )
    }
  }
}

// MARK: - Tracks

public class Tracks {
  var manifest: Manifest
  public var audiobookID: String
  public var tracks: [any Track] = []
  public var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

  public var token: String?

  init(manifest: Manifest, audiobookID: String, token: String?) {
    self.manifest = manifest
    self.audiobookID = audiobookID
    self.token = token
    initializeTracks()
  }

  public subscript(index: Int) -> (any Track)? {
    guard index >= 0 && index < tracks.count else {
      return nil
    }
    return tracks[index]
  }

  public var count: Int {
    tracks.count
  }

  public var first: (any Track)? {
    tracks.first
  }

  private func initializeTracks() {
    if let spine = manifest.spine, !spine.isEmpty {
      addTracksFromSpine(spine)
    } else if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
      addTracksFromReadingOrder(readingOrder)
    } else if let linksDict = manifest.linksDictionary, let contentLinks = linksDict.contentLinks,
              !contentLinks.isEmpty
    {
      addTracksFromLinks(contentLinks)
    } else if let linksArray = manifest.links, !linksArray.isEmpty {
      addTracksFromLinks(linksArray)
    }
  }

  private func addTracksFromReadingOrder(_ readingOrder: [Manifest.ReadingOrderItem]) {
    for (index, item) in readingOrder.enumerated() {
      if let track = createTrack(from: item, index: index) {
        tracks.append(track)
      }
    }
  }

  private func addTracksFromLinks(_ links: [Manifest.Link]) {
    for (index, link) in links.enumerated() {
      if let track = createTrack(from: link, index: index) {
        tracks.append(track)
      }
    }
  }

  private func createTrack(from item: Manifest.ReadingOrderItem, index: Int) -> (any Track)? {
    let urlString = item.href

    return TrackFactory.createTrack(
      from: manifest,
      title: item.title,
      urlString: urlString,
      audiobookID: audiobookID,
      index: index,
      duration: item.duration,
      token: token,
      key: item.href
    )
  }

  private func createTrack(from link: Manifest.Link, index: Int) -> (any Track)? {
    let title = link.title?.localizedTitle() ?? ""
    let bitrate = (link.bitrate ?? 64) * 1024
    var duration: Double

    if let explicitDuration = link.duration {
      duration = Double(explicitDuration)
    } else if let fileSizeInBytes = link.physicalFileLengthInBytes {
      let fileSizeInBits = Double(fileSizeInBytes) * 8.0
      duration = fileSizeInBits / Double(bitrate)
    } else {
      duration = 0
    }

    return TrackFactory.createTrack(
      from: manifest,
      title: title,
      urlString: link.href,
      audiobookID: audiobookID,
      index: index,
      duration: duration,
      token: token,
      key: link.href
    )
  }

  public func track(forHref href: String) -> (any Track)? {
    if let match = tracks.first(where: { $0.urls?.first?.absoluteString == href }) {
      return match
    }
    if let match = tracks.first(where: { $0.key == href }) {
      return match
    }

    let hrefURL = URL(string: href)
    let hrefLast = hrefURL?.lastPathComponent
    let hrefPath = hrefURL?.path
    if let match = tracks.first(where: { track in
      guard let url = track.urls?.first else {
        return false
      }
      return url.lastPathComponent == hrefLast || url.path == hrefPath
    }) {
      return match
    }

    if let match = tracks.first(where: { track in
      guard let urlStr = track.urls?.first?.absoluteString else {
        return false
      }
      return urlStr.hasSuffix(href) || urlStr.contains(href)
    }) {
      return match
    }

    return nil
  }

  public func track(forKey key: String) -> (any Track)? {
    tracks.first(where: { track in
      if track.key == key {
        return true
      }
      return false
    })
  }

  public func track(forTitle key: String) -> (any Track)? {
    let cleanedKey = key.replacingOccurrences(of: "urn:isbn:", with: "")

    return tracks.first { track in
      if let title = track.title, title.contains(cleanedKey) {
        return true
      }
      return false
    }
  }

  private func addTracksFromSpine(_ spine: [Manifest.SpineItem]) {
    for (index, item) in spine.enumerated() {
      if let track = createTrack(from: item, index: index) {
        tracks.append(track)
      }
    }
  }

  private func createTrack(from item: Manifest.SpineItem, index: Int) -> (any Track)? {
    TrackFactory.createTrack(
      from: manifest,
      title: item.title,
      urlString: item.href,
      audiobookID: audiobookID,
      index: index,
      duration: Double(item.duration),
      token: token,
      key: item.href
    )
  }

  public func track(forPart part: Int, sequence: Int) -> (any Track)? {
    tracks.first(where: { track in
      track.partNumber == part && track.chapterNumber == sequence
    })
  }

  public func previousTrack(_ track: any Track) -> (any Track)? {
    guard let currentIndex = tracks.first(where: { $0.id == track.id
    })?.index, currentIndex > 0 else {
      return nil
    }
    return tracks[currentIndex - 1]
  }

  public func nextTrack(_ track: any Track) -> (any Track)? {
    // Find the track in our array by id
    guard let foundTrack = tracks.first(where: { $0.id == track.id }) else {
<<<<<<< HEAD
=======
      ATLog(.warn, "nextTrack: Could not find track with id=\(track.id) in tracks array")
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
      return nil
    }
    
    let trackIndex = foundTrack.index
    
    // Check if we're at the last track
    guard trackIndex < tracks.count - 1 else {
<<<<<<< HEAD
      return nil
    }
    
    return tracks[trackIndex + 1]
=======
      ATLog(.debug, "nextTrack: Track index \(trackIndex) is last track (count=\(tracks.count))")
      return nil
    }
    
    // Validate that the index matches the array position
    let arrayIndex = tracks.firstIndex(where: { $0.id == track.id })
    if let arrIdx = arrayIndex, arrIdx != trackIndex {
      ATLog(.warn, "nextTrack: ⚠️ Index mismatch! track.index=\(trackIndex), array position=\(arrIdx)")
    }
    
    let nextTrack = tracks[trackIndex + 1]
    ATLog(.debug, "nextTrack: Returning track at index \(trackIndex + 1): key=\(nextTrack.key)")
    return nextTrack
>>>>>>> aecbe4a70c5eae6c54b7e4ea62161500f7365756
  }

  public subscript(index: Int) -> any Track {
    tracks[index]
  }

  public func deleteTracks() {
    tracks.forEach { track in
      track.downloadTask?.delete()
    }
  }

  public func duration(to position: TrackPosition) -> TimeInterval {
    guard position.track.index >= 0 && position.track.index < tracks.count else {
      return 0
    }

    let tracksDuration = tracks.prefix(position.track.index).reduce(0) { $0 + $1.duration }
    return tracksDuration + position.timestamp
  }
}
