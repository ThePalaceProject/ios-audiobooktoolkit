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

public class AudiobookPlaybackModel: ObservableObject {
    @Published private var reachability = Reachability()
    @Published var isWaitingForPlayer = false
    @Published var playbackProgress: Double = 0
    @Published var isDownloading = false
    @Published var overallDownloadProgress: Float = 0
    @Published var trackErrors: [String: Error] = [:]
    @Published var coverImage: UIImage?
    @Published var toastMessage: String = ""
    @Published private var _isPlaying: Bool = false
    
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var audiobookManager: AudiobookManager
    
    @Published var currentLocation: TrackPosition?
    private var pendingLocation: TrackPosition?
    private var suppressSavesUntil: Date?
    private var isNavigating = false
    
    var selectedLocation: TrackPosition? {
        didSet {
            guard let selectedLocation else { return }
            isNavigating = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.isNavigating {
                    print("Navigation timeout reached - clearing navigation state")
                    self.isNavigating = false
                }
            }
            
            if audiobookManager.audiobook.player.isLoaded && !isWaitingForPlayer {
                audiobookManager.audiobook.player.play(at: selectedLocation) { _ in
                    DispatchQueue.main.async {
                        self.isNavigating = false
                    }
                }
            } else {
                pendingLocation = selectedLocation
                isNavigating = false
            }
            currentLocation = selectedLocation
            saveLocation()
        }
    }
    
    let skipTimeInterval: TimeInterval = DefaultAudiobookManager.skipTimeInterval
    
    var offset: TimeInterval {
        if let currentLocation = currentLocation,
           let currentChapter = audiobookManager.currentChapter {
            do {
                let chapterOffset = try currentLocation - currentChapter.position
                return max(0.0, chapterOffset)
            } catch {
                return audiobookManager.currentOffset
            }
        }
        return audiobookManager.currentOffset
    }
    
    var duration: TimeInterval {
        audiobookManager.currentChapter?.duration ?? audiobookManager.currentDuration
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
        
        return audiobookManager.totalDuration - currentLocation.durationToSelf()
    }
    
    var currentChapterTitle: String {
        if let currentLocation, let title = try? audiobookManager.audiobook.tableOfContents.chapter(forPosition: currentLocation).title {
            return title
        } else if let title = audiobookManager.audiobook.tableOfContents.toc.first?.title, !title.isEmpty {
            return title
        } else if let index = currentLocation?.track.index {
            return String(format: "Track %d", index + 1)
        } else {
            return "--"
        }
    }
    
    var playbackSliderValueDescription: String {
        let percent = playbackProgress * 100
        return String(format: Strings.ScrubberView.playbackSliderValueDescription, percent)
    }
    
    var isPlaying: Bool {
        _isPlaying
    }
    
    var tracks: [any Track] {
        audiobookManager.networkService.tracks
    }
    
    public init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        if let firstTrack = audiobookManager.audiobook.tableOfContents.allTracks.first {
            self.currentLocation = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobookManager.audiobook.tableOfContents.tracks)
        }
        
        _isPlaying = audiobookManager.audiobook.player.isPlaying
        
        setupBindings()
        subscribeToPublisher()
        setupReactivePlaybackStateMonitoring()
        self.audiobookManager.networkService.fetch()
    }


    // MARK: - Public helpers

    public func jumpToInitialLocation(_ position: TrackPosition) {
        self.pendingLocation = position
        self.currentLocation = position
    }

    public func beginSaveSuppression(for seconds: TimeInterval) {
        suppressSavesUntil = Date().addingTimeInterval(seconds)
    }
    
    private func subscribeToPublisher() {
        subscriptions.removeAll()

        audiobookManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .overallDownloadProgress(let overallProgress):
                    self.isDownloading = overallProgress < 1
                    self.overallDownloadProgress = overallProgress
                case .positionUpdated(let position):
                    guard let position else { return }
                    
                    self.currentLocation = position
                    self.updateProgress()
                    if let target = self.pendingLocation, self.audiobookManager.audiobook.player.isLoaded {
                        self.pendingLocation = nil
                        self.audiobookManager.audiobook.player.play(at: target) { _ in }
                    }
                    
                case .playbackBegan(let position):
                    self.currentLocation = position
                    self.isWaitingForPlayer = false
                    self._isPlaying = true
                    self.isNavigating = false
                    self.updateProgress()
                    if let target = self.pendingLocation, self.audiobookManager.audiobook.player.isLoaded {
                        self.pendingLocation = nil
                        self.audiobookManager.audiobook.player.play(at: target) { _ in }
                    }
                    
                case .playbackCompleted(let position):
                    self.currentLocation = position
                    self.isWaitingForPlayer = false
                    self._isPlaying = false
                    self.updateProgress()
                    if let target = self.pendingLocation, self.audiobookManager.audiobook.player.isLoaded {
                        self.pendingLocation = nil
                        self.audiobookManager.audiobook.player.play(at: target) { _ in }
                    }
                    
                case .playbackUnloaded:
                    self._isPlaying = false
                    break
                case .playbackFailed(let position):
                    self.isWaitingForPlayer = false
                    self._isPlaying = false
                    if let position = position {
                        ATLog(.debug, "Playback error at position: \(position.timestamp)")
                    } else {
                        ATLog(.error, "Playback failed but position is nil.")
                    }
                    
                default:
                    break
                }
            }
            .store(in: &subscriptions)
        audiobookManager.statePublisher
            .compactMap { state -> TrackPosition? in
                if case .positionUpdated(let pos) = state { return pos }
                return nil
            }
            .throttle(for: .seconds(10), scheduler: RunLoop.main, latest: true)
            .filter { [weak self] position in
                guard let self = self else { return false }
                if let currentLocation = self.currentLocation {
                    return abs(currentLocation.timestamp - position.timestamp) > 2.0
                }
                return true
            }
            .sink { [weak self] _ in
                self?.saveLocation()
            }
            .store(in: &subscriptions)

        self.audiobookManager.fetchBookmarks { _ in }
    }
    
    private func setupReactivePlaybackStateMonitoring() {
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let currentPlayingState = self.audiobookManager.audiobook.player.isPlaying
                if self._isPlaying != currentPlayingState {
                    self._isPlaying = currentPlayingState
                }
            }
            .store(in: &subscriptions)
    }
    
    private func setupBindings() {
        self.reachability.startMonitoring()
        self.reachability.$isConnected
            .receive(on: RunLoop.current)
            .sink { [weak self] isConnected in
                if let self = self, isConnected && self.overallDownloadProgress != 0 {
                    self.audiobookManager.networkService.fetch()
                }
            }
            .store(in: &subscriptions)
    }
    
    private func updateProgress() {
        guard duration > 0 else {
            playbackProgress = 0
            return
        }
        playbackProgress = offset / duration
    }
    
    deinit {
        self.reachability.stopMonitoring()
        self.audiobookManager.audiobook.player.unload()
        subscriptions.removeAll()
    }
    
    func playPause() {
        let wasPlaying = isPlaying
        if wasPlaying {
            audiobookManager.pause()
            _isPlaying = false
        } else {
            audiobookManager.play()
            _isPlaying = true
        }
        saveLocation()
    }
    
    func pause() {
        saveLocation()
        audiobookManager.pause()
    }
    
    func stop() {
        _isPlaying = false
        saveLocation()
        audiobookManager.unload()
        subscriptions.removeAll()
    }
    
    private func saveLocation() {
        if let until = suppressSavesUntil, Date() < until { return }
        if let currentLocation { audiobookManager.saveLocation(currentLocation) }
    }

    public func persistLocation() {
        saveLocation()
    }

    
    func skipBack() {
        guard !isWaitingForPlayer || audiobookManager.audiobook.player.queuesEvents else {
            return
        }
        
        isWaitingForPlayer = true
        
        audiobookManager.audiobook.player.skipPlayhead(-skipTimeInterval) { [weak self] adjustedLocation in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let adjustedLocation = adjustedLocation {
                    self.currentLocation = adjustedLocation
                    self.saveLocation()
                } else {
                    if let currentLocation = self.currentLocation {
                        let fallbackPosition = currentLocation + (-self.skipTimeInterval)
                        self.currentLocation = fallbackPosition
                        self.saveLocation()
                        ATLog(.debug, "Skip back used fallback position calculation")
                    }
                }
                
                // Force UI progress update immediately after skip
                self.updateProgress()
                self.isWaitingForPlayer = false
            }
        }
    }
    
    func skipForward() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else {
            return
        }
        
        // Brief loading state for skip operations (acceptable UX)
        isWaitingForPlayer = true
        
        audiobookManager.audiobook.player.skipPlayhead(skipTimeInterval) { [weak self] adjustedLocation in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let adjustedLocation = adjustedLocation {
                    self.currentLocation = adjustedLocation
                    self.saveLocation()
                } else {
                    if let currentLocation = self.currentLocation {
                        let fallbackPosition = currentLocation + self.skipTimeInterval
                        self.currentLocation = fallbackPosition
                        self.saveLocation()
                        ATLog(.debug, "Skip forward used fallback position calculation")
                    }
                }
                
                // Force UI progress update immediately after skip
                self.updateProgress()
                self.isWaitingForPlayer = false
            }
        }
    }
    
    func move(to value: Double) {
        guard !isNavigating else {
            print("Seek blocked: navigation in progress")
            return
        }
       
        if let modernManager = audiobookManager as? DefaultAudiobookManager {
            modernManager.seekWithSlider(value: value) { [weak self] adjustedLocation in
                self?.currentLocation = adjustedLocation
                self?.saveLocation()
            }
        } else {
            // Legacy fallback
            self.audiobookManager.audiobook.player.move(to: value) { [weak self] adjustedLocation in
                self?.currentLocation = adjustedLocation
                self?.saveLocation()
            }
        }
    }
    
    
    public func downloadProgress(for chapter: Chapter) -> Double {
        audiobookManager.downloadProgress(for: chapter)
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
    
    public func updateCoverImage(_ image: UIImage?) {
        coverImage = image
        updateLockScreenCoverArtwork(image: image)
    }
    
    private func updateLockScreenCoverArtwork(image: UIImage?) {
        DispatchQueue.main.async {
            if let image = image {
                let itemArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    return image
                }
                
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
                info[MPMediaItemPropertyArtwork] = itemArtwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
