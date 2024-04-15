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

    private var progressUpdateSubscription: AnyCancellable?
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var audiobookManager: AudiobookManager

    var currentLocation: TrackPosition?

    let skipTimeInterval: TimeInterval = DefaultAudiobookManager.skipTimeInterval
    
    var offset: TimeInterval {
        Double(self.currentLocation?.timestamp ?? 0)
    }

    var duration: TimeInterval {
        Double(self.currentLocation?.track.duration ?? 0)
    }
    var timeLeft: TimeInterval {
        max(duration - offset, 0)
    }

    var timeLeftInBook: TimeInterval {
        guard let currentLocation else {
            return 0
        }

        return Double(currentLocation.tracks.totalDuration - currentLocation.timestamp)
    }

    var isPlaying: Bool {
        audiobookManager.audiobook.player.isPlaying
    }
    
    var tracks: [any Track] {
        audiobookManager.networkService.tracks
    }
        
    init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        if let firstTrack = audiobookManager.audiobook.tableOfContents.tracks.tracks.first {
            self.currentLocation = TrackPosition(track: firstTrack, timestamp: 0, tracks: audiobookManager.audiobook.tableOfContents.tracks)
        }

        self.audiobookManager.networkService.fetch()
        setupBindings()
        subscribeToPublisher()
    }
    
    private func subscribeToPublisher() {
        audiobookManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .positionUpdated(let position):
                    self?.currentLocation = position
                    self?.updateProgress()
                    
                case .playbackBegan(let position),
                        .playbackCompleted(let position):
                    self?.currentLocation = position
                    self?.isWaitingForPlayer = false
                    self?.updateProgress()

                case .playbackUnloaded:
                    self?.stop()
                case .playbackFailed(let position):
                    self?.isWaitingForPlayer = false
                    if let position = position {
                        ATLog(.debug, "Playback error at position: \(position.timestamp)")
                    }
                    
                case .refreshRequested, .locationPosted(_), .bookmarkSaved(_, _),
                        .bookmarksFetched(_), .bookmarkDeleted(_),
                        .error(_, _):
                    return
                default:
                    break
                }
            }
            .store(in: &subscriptions)
        //        self.audiobookManager.fetchBookmarks { _ in }
        //        self.audiobookManager.timerDelegate = self
        
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
        if let currentLocation = currentLocation {
            playbackProgress = currentLocation.timestamp / Double(currentLocation.track.duration)
        }
    }

    deinit {
        self.reachability.stopMonitoring()
        self.audiobookManager.audiobook.player.unload()
    }
    
    func playPause() {
        isWaitingForPlayer = true
        isPlaying ? audiobookManager.pause() : audiobookManager.play()
        audiobookManager.saveLocation()
    }
    
    func stop() {
        audiobookManager.saveLocation()
        audiobookManager.unload()
    }
    
    func skipBack() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else {
            return
        }

        isWaitingForPlayer = true
        audiobookManager.audiobook.player.skipPlayhead(-skipTimeInterval) { adjustedLocation in
            self.currentLocation = adjustedLocation
            self.audiobookManager.saveLocation()
            self.isWaitingForPlayer = false
        }
    }
    
    func skipForward() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else { return }
        isWaitingForPlayer = true
        audiobookManager.audiobook.player.skipPlayhead(skipTimeInterval) { adjustedLocation in
            self.currentLocation = adjustedLocation
            self.audiobookManager.saveLocation()
            self.isWaitingForPlayer = false
        }
    }

    func move(to value: Double) {
        self.audiobookManager.audiobook.player.skipPlayhead(value) { adjustedLocation in
            self.currentLocation = adjustedLocation
            self.isWaitingForPlayer = false
            self.audiobookManager.saveLocation()
        }
    }
    
    func setPlaybackRate(_ playbackRate: PlaybackRate) {
        audiobookManager.audiobook.player.playbackRate = playbackRate
    }
    
    func setSleepTimer(_ trigger: SleepTimerTriggerAt) {
        audiobookManager.sleepTimer.setTimerTo(trigger: trigger)
    }
    
//    func addBookmark(completion: @escaping (_ error: Error?) -> Void) {
//        await audiobookManager.saveBookmark(location: <#T##TrackPosition#>)
//    }
//    
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
    
    private func setupNetworkServiceSubscription() {
        audiobookManager.networkService.downloadStatePublisher
            .sink { [weak self] downloadState in
                switch downloadState {
                case .progress(track: let track, progress: let progress):
                    self?.overallDownloadProgress = progress
                    self?.isDownloading = progress < 1
                    break
                case .completed(track: let track):
                    self?.trackErrors.removeValue(forKey: track.id)
                    break
                case .error(track: let track, error: let error):
                    self?.trackErrors[track.id] = error
                    self?.isDownloading = false
                case .overallProgress(progress: let progress):
                    self?.overallDownloadProgress = progress
                    self?.isDownloading = progress < 1.0
                case .deleted(track: let track):
                    self?.trackErrors.removeValue(forKey: track.id)
                }
            }
            .store(in: &subscriptions)
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
