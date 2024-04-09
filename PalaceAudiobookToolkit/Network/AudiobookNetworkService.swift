//
//  AudiobookNetworkService.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/22/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import Combine

public enum DownloadState {
    case progress(track: Track, progress: Float)
    case completed(track: Track)
    case deleted(track: Track)
    case error(track: Track, error: Error)
    case overallProgress(progress: Float)
}


/// The protocol for managing the download of chapters. Implementers of
/// this protocol should not be concerned with the details of how
/// the downloads happen or any caching.
///
/// The purpose of an AudiobookNetworkService is to manage the download
/// tasks and tie them back to their spine elements
/// for delegates to consume.
public protocol AudiobookNetworkService: AnyObject {
    var tracks: [Track] { get }
    var downloadStatePublisher: PassthroughSubject<DownloadState, Never> { get }

    /// Implementers of this should attempt to download all
    /// spine elements in a serial order. Once the
    /// implementer has begun requesting files, calling this
    /// again should not fire more requests. If no request is
    /// in progress, fetch should always start at the first
    /// spine element.
    ///
    /// Implementations of this should be non-blocking.
    /// Updates for the status of each download task will
    /// come through delegate methods.
    func fetch()
    
    
    /// Implmenters of this should attempt to delete all
    /// spine elements.
    ///
    /// Implementations of this should be non-blocking.
    /// Updates for the status of each download task will
    /// come through delegate methods.
    func deleteAll()
}

public final class DefaultAudiobookNetworkService: AudiobookNetworkService {
    public var downloadStatePublisher = PassthroughSubject<DownloadState, Never>()
    
    public let tracks: [Track]
    private var cancellables: Set<AnyCancellable> = []
    
    public init(tracks: [Track]) {
        self.tracks = tracks
        setupDownloadTasks()
    }
    
    public func fetch() {
        tracks.forEach {
            $0.downloadTask?.fetch()

        }
    }

    public func deleteAll() {
        tracks.forEach { track in
            track.downloadTask?.delete()
        }
    }
    
    private func setupDownloadTasks() {
        tracks.forEach { track in
            guard let downloadTask = track.downloadTask else { return }
            
            downloadTask.statePublisher
                .sink { [weak self] state in
                    switch state {
                    case .progress(let progress):
                        self?.downloadStatePublisher.send(.progress(track: track, progress: progress))
                    case .completed:
                        self?.downloadStatePublisher.send(.completed(track: track))
                    case .error(let error):
                        self?.downloadStatePublisher.send(.error(track: track, error: error))
                    case .deleted:
                        self?.downloadStatePublisher.send(.deleted(track: track))
                        break
                    }
                }
                .store(in: &cancellables)
        }
    }
}
