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
    func cleanup()
}

public final class DefaultAudiobookNetworkService: AudiobookNetworkService {
    public var downloadStatePublisher = PassthroughSubject<DownloadState, Never>()
    public let tracks: [any Track]
    private var cancellables: Set<AnyCancellable> = []
    private var progressDictionary: [String: Float] = [:]
    private var downloadStatus: [String: DownloadTaskState] = [:]
    private let queue = DispatchQueue(label: "com.yourapp.progressDictionaryQueue", attributes: .concurrent)
    private var currentDownloadIndex: Int = 0
    public let decryptor: DRMDecryptor?
    
    public init(tracks: [any Track], decryptor: DRMDecryptor? = nil) {
        self.tracks = tracks
        self.decryptor = decryptor
        setupDownloadTasks()
    }
    
    public func fetch() {
        startDownload(at: currentDownloadIndex)
    }
    
    public func fetchUndownloadedTracks() {
        startNextUndownloadedTrack()
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
            startNextDownload()
        case .error(let error):
            downloadStatePublisher.send(.error(track: track, error: error))
            updateDownloadStatus(for: track, state: .error(error))
            startNextDownload()
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
    
    private func startDownload(at index: Int) {
        guard index < tracks.count else { return }
        let track = tracks[index]
        currentDownloadIndex = index
        
        if let lcpTask = track.downloadTask as? LCPDownloadTask, let decryptedUrls = lcpTask.decryptedUrls, let decryptor = decryptor {
            startLCPDecryption(task: lcpTask, originalUrls: lcpTask.urls, decryptedUrls: decryptedUrls, decryptor: decryptor)
            return
        }

        if track.downloadTask?.downloadProgress ?? 0.0 < 1.0 {
            track.downloadTask?.fetch()
        } else {
            startNextDownload()
        }
    }

    private func startLCPDecryption(task: LCPDownloadTask, originalUrls: [URL], decryptedUrls: [URL], decryptor: DRMDecryptor) {
        let fileManager = FileManager.default
        let total = decryptedUrls.count
        var completed = 0

        let missingPairs: [(URL, URL)] = zip(originalUrls, decryptedUrls).filter { (_, dst) in !fileManager.fileExists(atPath: dst.path) }
        if missingPairs.isEmpty {

            task.downloadProgress = 1.0
            let track = tracks[currentDownloadIndex]
            updateProgress(1.0, for: track)
            downloadStatePublisher.send(.completed(track: track))
            updateDownloadStatus(for: track, state: .completed)
            startNextDownload()
            return
        }

        for (src, dst) in missingPairs {
            decryptor.decrypt(url: src, to: dst) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.downloadStatePublisher.send(.error(track: self.tracks[self.currentDownloadIndex], error: error))
                    self.updateDownloadStatus(for: self.tracks[self.currentDownloadIndex], state: .error(error))
                } else {
                    completed += 1
                    let progress = Float(completed) / Float(total)
                    task.downloadProgress = progress
                    self.downloadStatePublisher.send(.progress(track: self.tracks[self.currentDownloadIndex], progress: progress))
                    if completed == total {
                        self.downloadStatePublisher.send(.completed(track: self.tracks[self.currentDownloadIndex]))
                        self.updateDownloadStatus(for: self.tracks[self.currentDownloadIndex], state: .completed)
                        self.startNextDownload()
                    }
                }
            }
        }
    }
    
    private func startNextDownload() {
        let nextIndex = currentDownloadIndex + 1
        if nextIndex < tracks.count {
            startDownload(at: nextIndex)
        }
    }
    
    private func startNextUndownloadedTrack() {
        for index in currentDownloadIndex..<tracks.count {
            let track = tracks[index]
            if track.downloadTask?.needsRetry ?? false {
                currentDownloadIndex = index
                track.downloadTask?.fetch()
                break
            }
        }
    }


    deinit {
        cleanup() 
    }

    public func cleanup() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        tracks.forEach { track in
            if let lcpTask = track.downloadTask as? LCPDownloadTask {
                ATLog(.debug, "🎵 [NetworkService] Keeping LCP download task running for track: \(track.key)")
            } else {
                track.downloadTask?.cancel()
            }
        }
    }
}
