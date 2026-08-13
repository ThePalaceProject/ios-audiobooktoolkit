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
    #if FEATURE_FINDAWAY
    // Defense-in-depth: `FindawayTrack` builds a `FindawayDownloadTask`, which
    // constructs `FAEDownloadRequest` (AudioEngine). When AudioEngine isn't
    // linked (the open, no-DRM build) fall through to `OpenAccessTrack` rather
    // than force-unwrapping an absent Obj-C class. The `AudiobookFactory` gate
    // already keeps a no-DRM catalog off this path; this closes the residual
    // window if a Findaway-typed manifest ever reaches the open build.
    case .findaway where FindawaySupport.isAvailable:
      try? FindawayTrack(
        manifest: manifest,
        urlString: urlString,
        audiobookID: audiobookID,
        title: title,
        duration: duration,
        index: index,
        token: token
      )
    #endif
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

/// The ordered set of audio files behind one audiobook.
///
/// # Why this is `Sendable`
///
/// `TrackPosition` carries a `Tracks` reference, and a `TrackPosition` travels
/// between the player, the download scheduler, the bookmark store and the UI,
/// each on a different thread. `TrackPosition` cannot be `Sendable` until this
/// type is, so this is the gate for the whole model layer.
///
/// The claim is a plain `Sendable` conformance, not `@unchecked`, and it rests
/// on the compiler checking every stored property:
///
/// - `manifest`, `audiobookID`, `tracks` are `let`. The track array used to be
///   built by appending to `self.tracks` from inside `init`; it is now produced
///   whole by the `static` builders below and assigned once, so there is no
///   window in which it changes.
/// - `_token` and `_fulfillURL` are `let` boxes. Both properties they back are
///   written AFTER construction — `token` by `OpenAccessPlayer`'s bearer-token
///   refresh, `fulfillURL` by `Audiobook.setFulfillURL(_:)` during player setup
///   — which is exactly why neither could be a plain `var`. All mutation goes
///   through `LockIsolated`.
///
/// - Important: `token` deliberately does NOT propagate to the already-built
///   tracks. Each track captured the token it was constructed with; refreshing
///   it here only affects readers of `tracks.token` (the player). That was the
///   behaviour before this change and it is preserved, not fixed, here.
public final class Tracks: Sendable {
  let manifest: Manifest
  public let audiobookID: String
  public let tracks: [any Track]
  public var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

  private let _token: LockIsolated<String?>

  /// The bearer token most recently obtained for this audiobook.
  public var token: String? {
    get { _token.value }
    set { _token.value = newValue }
  }

  private let _fulfillURL = LockIsolated<URL?>(nil)

  /// The CM fulfill URL for refreshing expired bearer tokens.
  ///
  /// Setting this propagates the URL to every `OpenAccessDownloadTask` behind
  /// these tracks. That propagation used to be a `didSet`; a computed property
  /// has no `didSet`, so the loop is written out by hand. Dropping it would
  /// leave the download tasks with no fulfill URL, `refreshTokenAndRetry` would
  /// bail at its `guard let fulfillURL`, and a download whose bearer token
  /// expired mid-flight would fail permanently instead of refreshing — silently,
  /// because nothing else reads the URL. `BearerTokenRefreshTests`'
  /// propagation tests exist to make that removal loud.
  ///
  /// - Important: the store and the propagation happen under this box's lock so
  ///   that two concurrent writers cannot leave the tasks holding a different
  ///   URL from the one `fulfillURL` reports. That nests
  ///   `OpenAccessDownloadTask._fulfillURL`'s lock inside this one. The reverse
  ///   order does not exist: `OpenAccessDownloadTask` holds no reference to
  ///   `Tracks` (it only names it in a comment), so there is no path that takes
  ///   a task's lock and then this one. Do not add one.
  public var fulfillURL: URL? {
    get { _fulfillURL.value }
    set {
      _fulfillURL.withValue { stored in
        stored = newValue
        for track in tracks {
          if let oaTask = track.downloadTask as? OpenAccessDownloadTask {
            oaTask.fulfillURL = newValue
          }
        }
      }
    }
  }

  init(manifest: Manifest, audiobookID: String, token: String?) {
    self.manifest = manifest
    self.audiobookID = audiobookID
    _token = LockIsolated(token)
    tracks = Tracks.buildTracks(manifest: manifest, audiobookID: audiobookID, token: token)
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

  /// Builds the whole track array before it is assigned, so `tracks` can be a
  /// `let`. Every helper below is `static` for the same reason: an instance
  /// method cannot run before all stored properties are initialised.
  private static func buildTracks(
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) -> [any Track] {
    var tracks: [any Track] = []

    if let spine = manifest.spine, !spine.isEmpty {
      ATLog(.debug, "Tracks: Initializing \(spine.count) tracks from spine")
      addTracksFromSpine(spine, into: &tracks, manifest: manifest, audiobookID: audiobookID, token: token)
    } else if let readingOrder = manifest.readingOrder, !readingOrder.isEmpty {
      ATLog(.debug, "Tracks: Initializing \(readingOrder.count) tracks from readingOrder")
      addTracksFromReadingOrder(readingOrder, into: &tracks, manifest: manifest, audiobookID: audiobookID, token: token)
    } else if let linksDict = manifest.linksDictionary, let contentLinks = linksDict.contentLinks,
              !contentLinks.isEmpty
    {
      ATLog(.debug, "Tracks: Initializing \(contentLinks.count) tracks from contentLinks")
      addTracksFromLinks(contentLinks, into: &tracks, manifest: manifest, audiobookID: audiobookID, token: token)
    } else if let linksArray = manifest.links, !linksArray.isEmpty {
      ATLog(.debug, "Tracks: Initializing \(linksArray.count) tracks from links")
      addTracksFromLinks(linksArray, into: &tracks, manifest: manifest, audiobookID: audiobookID, token: token)
    } else {
      ATLog(.error, "Tracks: No spine, readingOrder, contentLinks, or links found in manifest for audiobook \(audiobookID)")
    }

    ATLog(.debug, "Tracks: Created \(tracks.count) tracks for audiobook \(audiobookID)")
    if tracks.isEmpty {
      ATLog(.error, "Tracks: Zero tracks created - manifest may be malformed. Keys: \(manifest.metadata?.title ?? "unknown title")")
    }

    return tracks
  }

  private static func addTracksFromReadingOrder(
    _ readingOrder: [Manifest.ReadingOrderItem],
    into tracks: inout [any Track],
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) {
    for (index, item) in readingOrder.enumerated() {
      if let track = createTrack(from: item, index: index, manifest: manifest, audiobookID: audiobookID, token: token) {
        tracks.append(track)
      } else {
        ATLog(.warn, "Tracks: Failed to create track \(index) from readingOrder (href: \(item.href ?? "nil"), duration: \(item.duration))")
      }
    }
  }

  private static func addTracksFromLinks(
    _ links: [Manifest.Link],
    into tracks: inout [any Track],
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) {
    for (index, link) in links.enumerated() {
      if let track = createTrack(from: link, index: index, manifest: manifest, audiobookID: audiobookID, token: token) {
        tracks.append(track)
      }
    }
  }

  private static func createTrack(
    from item: Manifest.ReadingOrderItem,
    index: Int,
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) -> (any Track)? {
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

  private static func createTrack(
    from link: Manifest.Link,
    index: Int,
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) -> (any Track)? {
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

  private static func addTracksFromSpine(
    _ spine: [Manifest.SpineItem],
    into tracks: inout [any Track],
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) {
    for (index, item) in spine.enumerated() {
      if let track = createTrack(from: item, index: index, manifest: manifest, audiobookID: audiobookID, token: token) {
        tracks.append(track)
      }
    }
  }

  private static func createTrack(
    from item: Manifest.SpineItem,
    index: Int,
    manifest: Manifest,
    audiobookID: String,
    token: String?
  ) -> (any Track)? {
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
      return nil
    }
    
    let trackIndex = foundTrack.index
    
    // Check if we're at the last track
    guard trackIndex < tracks.count - 1 else {
      return nil
    }
    
    return tracks[trackIndex + 1]
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
