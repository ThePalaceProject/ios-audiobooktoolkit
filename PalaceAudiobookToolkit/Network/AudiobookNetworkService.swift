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
    case downloadComplete
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
    /// come through downloadStatePublisher.
    func fetch()
    
    /// Implementations of this should be non-blocking.
    /// Updates for the status of each download task will
    /// come through downloadStatePublisher.
    func fetchUndownloadedTracks()

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
    private var downloadStatus: [String: DownloadTaskState] = [:]
    private let downloadQueue = DispatchQueue(label: "com.palace.audiobook.downloadQueue", attributes: .concurrent)
    private let queue = DispatchQueue(label: "com.yourapp.progressDictionaryQueue", attributes: .concurrent)
    
    public init(tracks: [any Track]) {
        self.tracks = tracks
        setupDownloadTasks()
    }
    
    public func fetch() {
        tracks.forEach { $0.downloadTask?.fetch() }
    }
    
    public func fetchUndownloadedTracks() {
        tracks.forEach {
            if $0.downloadTask?.needsRetry ?? false {
                $0.downloadTask?.fetch()
            }
        }
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
            updateDownloadStatus(for: track, state: .completed)
        case .error(let error):
            downloadStatePublisher.send(.error(track: track, error: error))
            updateDownloadStatus(for: track, state: .error(error))
        case .deleted:
            downloadStatePublisher.send(.deleted(track: track))
        }
        
        checkIfAllTasksFinished()
    }
    
    private func updateProgress(_ progress: Float, for track: any Track) {
        queue.async(flags: .barrier) {
            self.progressDictionary[track.key] = progress
            DispatchQueue.main.async {
                self.updateOverallProgress()
                self.downloadStatePublisher.send(.progress(track: track, progress: progress))
            }
        }
    }
    
    private func updateOverallProgress() {
        queue.sync {
            guard !progressDictionary.isEmpty else {
                return
            }
            
            let totalProgress = progressDictionary.values.reduce(0, +)
            let overallProgress = totalProgress / Float(tracks.count)
            DispatchQueue.main.async {
                self.downloadStatePublisher.send(.overallProgress(progress: overallProgress))
            }
        }
    }
    
    private func updateDownloadStatus(for track: any Track, state: DownloadTaskState) {
        queue.async(flags: .barrier) {
            self.downloadStatus[track.key] = state
        }
    }
    
    private func checkIfAllTasksFinished() {
        queue.sync {
            let allFinished = tracks.allSatisfy { track in
                if let state = downloadStatus[track.key] {
                    switch state {
                    case .completed, .error:
                        return true
                    default:
                        return false
                    }
                }
                return false
            }
            
            if allFinished {
                DispatchQueue.main.async {
                    self.downloadStatePublisher.send(.downloadComplete)
                }
            }
        }
    }
}

