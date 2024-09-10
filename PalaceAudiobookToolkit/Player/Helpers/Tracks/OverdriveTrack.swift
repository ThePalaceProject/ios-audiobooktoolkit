//
//  OverdriveTrack.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/26/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import Combine

import Foundation
import AVFoundation
import Combine

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
        get {
            requestDurationUpdate()
            return _duration
        }
    }

    required init(
        manifest: Manifest,
        urlString: String?,
        audiobookID: String,
        title: String?,
        duration: Double,
        index: Int,
        token: String? = nil,
        key: String?
    ) throws {
        guard let urlString, let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }

        self.key = "urn:org.thepalaceproject:readingOrder:\(String(describing: index))"
        self.url = url
        self.title = title
        self.index = index
        self.mediaType = manifest.trackMediaType
        self.downloadTask = OverdriveDownloadTask(key: self.key, url: url, mediaType: mediaType, bookID: audiobookID)

        downloadTask?.statePublisher
            .sink(receiveValue: { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .completed:
                    self.updateDuration()
                default:
                    break
                }
            })
            .store(in: &cancellables)
    }

    func updateDuration() {
        guard let localURL = (downloadTask as? OverdriveDownloadTask)?.localDirectory() else { return }

        let asset = AVURLAsset(url: localURL)
        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            var error: NSError? = nil
            let status = asset.statusOfValue(forKey: "duration", error: &error)
            if status == .loaded {
                let duration = CMTimeGetSeconds(asset.duration)
                DispatchQueue.main.async {
                    self._duration = duration
                }
            } else {
                print("Failed to load duration with error: \(error?.localizedDescription ?? "unknown error")")
            }
        }
    }

    func requestDurationUpdate() {
        updateDuration()
    }
}
