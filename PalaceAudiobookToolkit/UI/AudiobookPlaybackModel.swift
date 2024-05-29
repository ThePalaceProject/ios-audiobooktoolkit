//
//  AudiobookPlaybackController.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 12/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine
import MediaPlayer

class AudiobookPlaybackModel: ObservableObject {
    @ObservedObject private var reachability = Reachability()
    @Published var isWaitingForPlayer = false
    @Published var playbackProgress: Double = 0
    @Published var isDownloading = false
    @Published var overallDownloadProgress: Float = 0
    @Published var trackErrors: [String: Error] = [:]
    @Published var coverImage: UIImage?

    private var subscriptions: Set<AnyCancellable> = []
    private(set) var audiobookManager: AudiobookManager

    @Published var currentLocation: TrackPosition?
    var selectedLocation: TrackPosition? {
        didSet {
            if let selectedLocation {
                audiobookManager.audiobook.player.play(at: selectedLocation) { _ in }
            }
        }
    }

    let skipTimeInterval: TimeInterval = DefaultAudiobookManager.skipTimeInterval
    
    var offset: TimeInterval {
        audiobookManager.currentOffset
    }

    var duration: TimeInterval {
        audiobookManager.currentDuration
    }

    var timeLeft: TimeInterval {
        max(duration - offset, 0.0)
    }


    var timeLeftInBook: TimeInterval {
        guard let currentLocation else {
            return audiobookManager.totalDuration
        }
        
        guard currentLocation.timestamp.isFinite else {
            return audiobookManager.totalDuration
        }

        return audiobookManager.totalDuration - currentLocation.timestamp
    }
    
    var currentChapterTitle: String {
        guard let currentChapter = audiobookManager.currentChapter else {
            if let index = currentLocation?.track.index {
                return String(format: "Track %d", index)
            } else {
                return "--"
            }
        }
        
        return currentChapter.title
    }

    var isPlaying: Bool {
        audiobookManager.audiobook.player.isPlaying
    }
    
    var tracks: [any Track] {
        audiobookManager.networkService.tracks
    }
        
    init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        if let firstTrack = audiobookManager.audiobook.tableOfContents.allTracks.first {
            self.currentLocation = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobookManager.audiobook.tableOfContents.tracks)
        }

        setupBindings()
        subscribeToPublisher()
        self.audiobookManager.networkService.fetch()
    }
    
    private func subscribeToPublisher() {
        audiobookManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .overallDownloadProgress(let overallProgress):
                    isDownloading = overallProgress < 1
                    isWaitingForPlayer = isDownloading

                    overallDownloadProgress = overallProgress
                case .positionUpdated(let position):
                    guard let position else { return }
                    self.currentLocation = position
                    self.updateProgress()
                    
                case .playbackBegan(let position), .playbackCompleted(let position):
                    self.currentLocation = position
                    self.isWaitingForPlayer = false
                    self.updateProgress()
                    
                case .playbackUnloaded:
                    break
                case .playbackFailed(let position):
                    self.isWaitingForPlayer = false
                    if let position = position {
                        ATLog(.debug, "Playback error at position: \(position.timestamp)")
                    }
                    
                default:
                    break
                }
            }
            .store(in: &subscriptions)
            
        self.audiobookManager.fetchBookmarks { _ in }
    }

    private func setupBindings() {
        self.reachability.startMonitoring()
        self.reachability.$isConnected
            .receive(on: RunLoop.current)
            .sink { isConnected in
                if isConnected && self.overallDownloadProgress != 0 {
                    self.audiobookManager.networkService.fetch()
                }
            }
            .store(in: &subscriptions)
        
    }

    private func updateProgress() {
        playbackProgress = offset/duration
    }

    deinit {
        self.reachability.stopMonitoring()
        self.audiobookManager.audiobook.player.unload()
        subscriptions.removeAll()
    }
    
    func playPause() {
        isPlaying ? audiobookManager.pause() : audiobookManager.play()
        saveLocation()
    }
    
    func stop() {
        saveLocation()
        audiobookManager.unload()
        subscriptions.removeAll()
    }

    private func saveLocation() {
        if let currentLocation {
            audiobookManager.saveLocation(currentLocation)
        }
    }

    func skipBack() {
        guard !isWaitingForPlayer || audiobookManager.audiobook.player.queuesEvents else {
            return
        }

        isWaitingForPlayer = true
        audiobookManager.audiobook.player.skipPlayhead(-skipTimeInterval) { [weak self] adjustedLocation in
            self?.currentLocation = adjustedLocation
            self?.saveLocation()
            self?.isWaitingForPlayer = false
        }
    }
    
    func skipForward() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else {
            return
        }
        
        isWaitingForPlayer = true
        audiobookManager.audiobook.player.skipPlayhead(skipTimeInterval) { [weak self] adjustedLocation in
            self?.currentLocation = adjustedLocation
            self?.saveLocation()
            self?.isWaitingForPlayer = false
        }
    }


    func move(to value: Double) {
        isWaitingForPlayer = true

        self.audiobookManager.audiobook.player.move(to: value) { [weak self] adjustedLocation in
            self?.currentLocation = adjustedLocation
            self?.saveLocation()
            self?.isWaitingForPlayer = false
        }
    }
    
    func setPlaybackRate(_ playbackRate: PlaybackRate) {
        audiobookManager.audiobook.player.playbackRate = playbackRate
    }
    
    func setSleepTimer(_ trigger: SleepTimerTriggerAt) {
        audiobookManager.sleepTimer.setTimerTo(trigger: trigger)
    }
    
    func addBookmark(completion: @escaping (_ error: Error?) -> Void) {
        guard let currentLocation else {
            completion(BookmarkError.bookmarkFailedToSave)
            return
        }
        
        audiobookManager.saveBookmark(at: currentLocation) { result in
            switch result {
            case .success:
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }
    
    // MARK: - Player timer delegate
    
    func audiobookManager(_ audiobookManager: AudiobookManager, didUpdate timer: Timer?) {
        currentLocation = audiobookManager.audiobook.player.currentTrackPosition
    }
    
    // MARK: - PlayerDelegate
    
    func player(_ player: Player, didBeginPlaybackOf track: any Track) {
        currentLocation = TrackPosition(track: track, timestamp: 0, tracks: audiobookManager.audiobook.player.tableOfContents.tracks)
        isWaitingForPlayer = false
    }
    
    func player(_ player: Player, didStopPlaybackOf trackPosition: TrackPosition) {
        currentLocation = trackPosition
        isWaitingForPlayer = false
    }
    
    func player(_ player: Player, didComplete track: any Track) {
        isWaitingForPlayer = false
    }
    
    func player(_ player: Player, didFailPlaybackOf track: any Track, withError error: NSError?) {
        isWaitingForPlayer = false
    }
    
    func playerDidUnload(_ player: Player) {
        isWaitingForPlayer = false
    }
    
    // MARK: - Media Player
    
    func updateCoverImage(_ image: UIImage?) {
        coverImage = image
        updateLockScreenCoverArtwork(image: image)
    }
    
    private func updateLockScreenCoverArtwork(image: UIImage?) {
        if let image = image {
            let itemArtwork = MPMediaItemArtwork.init(boundsSize: image.size) { requestedSize -> UIImage in
                // Scale aspect fit to size requested by system
                let rect = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: requestedSize))
                UIGraphicsBeginImageContextWithOptions(rect.size, true, 0.0)
                image.draw(in: CGRect(origin: .zero, size: rect.size))
                let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                if let scaledImage = scaledImage {
                    return scaledImage
                } else {
                    return image
                }
            }
            
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
            info[MPMediaItemPropertyArtwork] = itemArtwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

}
