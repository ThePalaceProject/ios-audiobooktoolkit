//
//  OverdriveTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/26/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation

class OverdriveTrack: Track {
  var key: String = ""
  var downloadTask: (any DownloadTask)?
  var title: String?
  var index: Int
  private var _duration: TimeInterval = 0
  var url: URL
  var urls: [URL]? { [url] }
  let mediaType: TrackMediaType

  var cancellables = Set<AnyCancellable>()

  var duration: TimeInterval {
    if _duration <= 0 {
      requestDurationUpdate()
    }
    return _duration
  }

  required init(
    manifest: Manifest,
    urlString: String?,
    audiobookID: String,
    title: String?,
    duration: Double,
    index: Int,
    token _: String? = nil,
    key _: String?
  ) throws {
    guard let urlString, let url = URL(string: urlString) else {
      throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
    }

    key = "urn:org.thepalaceproject:readingOrder:\(String(describing: index))"
    self.url = url
    self.title = title
    self.index = index
    mediaType = manifest.trackMediaType

    _duration = duration > 0 ? duration : 0

    downloadTask = OverdriveDownloadTask(key: key, url: url, mediaType: mediaType, bookID: audiobookID)

    downloadTask?.statePublisher
      .sink(receiveValue: { [weak self] state in
        guard let self = self else {
          return
        }
        switch state {
        case .completed:
          updateDuration()
        default:
          break
        }
      })
      .store(in: &cancellables)
  }

  func updateDuration() {
    guard let localURL = (downloadTask as? OverdriveDownloadTask)?.localDirectory() else {
      return
    }

    let asset = AVURLAsset(url: localURL)
    asset.loadValuesAsynchronously(forKeys: ["duration"]) {
      var error: NSError?
      let status = asset.statusOfValue(forKey: "duration", error: &error)
      if status == .loaded {
        let duration = CMTimeGetSeconds(asset.duration)
        DispatchQueue.main.async {
          self._duration = duration
        }
      }
    }
  }

  func requestDurationUpdate() {
    updateDuration()
  }
}
