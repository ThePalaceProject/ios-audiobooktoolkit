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
    case progress(track: any Track, progress: Float)
    case completed(track: any Track)
    case deleted(track: any Track)
    case error(track: any Track, error: Error?)
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
    var tracks: [any Track] { get }
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
    public let tracks: [any Track]
    private var cancellables: Set<AnyCancellable> = []
    private var progressDictionary: [String: Float] = [:]
    
    public init(tracks: [any Track]) {
        self.tracks = tracks
        setupDownloadTasks()
    }
    
    public func fetch() {
        tracks.forEach { $0.downloadTask?.fetch() }
    }
    
    public func deleteAll() {
        tracks.forEach { $0.downloadTask?.delete() }
    }
    
    private func setupDownloadTasks() {
        tracks.forEach { track in
            guard let downloadTask = track.downloadTask else { return }
            downloadTask.statePublisher
                .sink { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .progress(let progress):
                        self.progressDictionary[track.key] = progress
                        self.updateOverallProgress()
                        self.downloadStatePublisher.send(.progress(track: track, progress: progress))
                    case .completed:
                        self.downloadStatePublisher.send(.completed(track: track))
                    case .error(let error):
                        self.downloadStatePublisher.send(.error(track: track, error: error))
                    case .deleted:
                        self.downloadStatePublisher.send(.deleted(track: track))
                    }
                }
                .store(in: &self.cancellables)
        }
    }

    private func updateOverallProgress() {
        let totalProgress = progressDictionary.values.reduce(0, +)
        let overallProgress = totalProgress / Float(tracks.count)
        downloadStatePublisher.send(.overallProgress(progress: overallProgress))
    }
}

