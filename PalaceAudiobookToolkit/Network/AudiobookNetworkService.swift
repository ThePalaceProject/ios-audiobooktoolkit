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
    private let downloadQueue = DispatchQueue(label: "com.palace.audiobook.downloadQueue")

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
                    self.handleDownloadState(state, for: track)
                }
                .store(in: &self.cancellables)
        }
    }
    
    private func handleDownloadState(_ state: DownloadTaskState, for track: any Track) {
        switch state {
        case .progress(let progress):
            updateProgress(progress, for: track)
        case .completed:
            updateProgress(1.0, for: track)
            downloadStatePublisher.send(.completed(track: track))
        case .error(let error):
            downloadStatePublisher.send(.error(track: track, error: error))
        case .deleted:
            downloadStatePublisher.send(.deleted(track: track))
        }
    }
    
    private func updateProgress(_ progress: Float, for track: any Track) {
        downloadQueue.async {
            self.progressDictionary[track.key] = progress
            DispatchQueue.main.async {
                self.updateOverallProgress()
                self.downloadStatePublisher.send(.progress(track: track, progress: progress))
            }
        }
    }

    private func updateOverallProgress() {
        let totalProgress = progressDictionary.values.reduce(0, +)
        let overallProgress = totalProgress / Float(tracks.count)
        downloadStatePublisher.send(.overallProgress(progress: overallProgress))
    }
}

