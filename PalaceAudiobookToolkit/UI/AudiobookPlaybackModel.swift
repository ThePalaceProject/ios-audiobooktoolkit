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
    @Published var targetProgress: Double = 0
    @Published var isDownloading = false
    @Published var overallDownloadProgress: Float = 0
    @Published var trackErrors: [String: Error] = [:]
    @Published var coverImage: UIImage?
    @Published var toastMessage: String = ""
    
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var audiobookManager: AudiobookManager
    
    @Published var currentLocation: TrackPosition?
    private var pendingLocation: TrackPosition?
    private var suppressSavesUntil: Date?
    var selectedLocation: TrackPosition? {
        didSet {
            guard let selectedLocation else { return }
            
            // Clear any progress suppression for chapter navigation
            suppressBackgroundProgressUpdates = false
            suppressUpdates = false
            suppressionWorkItem?.cancel()
            
            // Update current location immediately
            currentLocation = selectedLocation
            
            // Recalculate progress for new chapter position
            recalculateProgressForNewPosition(selectedLocation)
            
            if audiobookManager.audiobook.player.isLoaded && !isWaitingForPlayer {
                audiobookManager.audiobook.player.play(at: selectedLocation) { _ in }
            } else {
                pendingLocation = selectedLocation
            }
            
            saveLocation()
        }
    }
    
    let skipTimeInterval: TimeInterval = DefaultAudiobookManager.skipTimeInterval
    
    var offset: TimeInterval {
        audiobookManager.currentOffset
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
        audiobookManager.audiobook.player.isPlaying
    }
    
    var tracks: [any Track] {
        audiobookManager.networkService.tracks
    }
    
    public init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        if let firstTrack = audiobookManager.audiobook.tableOfContents.allTracks.first {
            self.currentLocation = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: audiobookManager.audiobook.tableOfContents.tracks)
        }
        
        setupBindings()
        subscribeToPublisher()
        self.audiobookManager.networkService.fetch()
    }

    // MARK: - Public helpers

    // Sets the desired starting location and lets the model coordinate playback
    public func jumpToInitialLocation(_ position: TrackPosition) {
        // Seed UI immediately; player will move on next ticks
        self.pendingLocation = position
        self.currentLocation = position
    }

    // Suppress posting/saving positions until a given offset from now
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
                    
                case .playbackBegan(let position), .playbackCompleted(let position):
                    self.currentLocation = position
                    self.isWaitingForPlayer = false
                    self.updateProgress()
                    if let target = self.pendingLocation, self.audiobookManager.audiobook.player.isLoaded {
                        self.pendingLocation = nil
                        self.audiobookManager.audiobook.player.play(at: target) { _ in }
                    }
                    
                case .playbackUnloaded:
                    break
                case .playbackFailed(let position):
                    self.isWaitingForPlayer = false
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
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.saveLocation()
            }
            .store(in: &subscriptions)

        self.audiobookManager.fetchBookmarks { _ in }
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
        // Skip updates if suppressed to prevent flicker
        guard !suppressUpdates && !suppressBackgroundProgressUpdates else { return }
        
        guard duration > 0 else {
            playbackProgress = 0
            targetProgress = 0
            return
        }
        
        let newProgress = offset / duration
        playbackProgress = newProgress
        
        // Only update target progress if we're not in a seeking operation
        if !isWaitingForPlayer {
            targetProgress = newProgress
        }
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
        // Skip saves during suppression window
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
        defer { isWaitingForPlayer = false }
        
        audiobookManager.audiobook.player.skipPlayhead(-skipTimeInterval) { [weak self] adjustedLocation in
            self?.currentLocation = adjustedLocation
            self?.saveLocation()
        }
    }
    
    func skipForward() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else {
            return
        }
        
        isWaitingForPlayer = true
        defer { isWaitingForPlayer = false }
        
        audiobookManager.audiobook.player.skipPlayhead(skipTimeInterval) { [weak self] adjustedLocation in
            self?.currentLocation = adjustedLocation
            self?.saveLocation()
        }
    }
    
    func move(to value: Double) {
        // Prevent UI flicker by suppressing updates during seeking
        isWaitingForPlayer = true
        
        // Suppress progress updates briefly to prevent flicker
        suppressProgressUpdates(for: 0.3)
        
        // Use enhanced seeking with smooth UI
        Task { @MainActor in
            do {
                if let modernManager = audiobookManager as? DefaultAudiobookManager {
                    modernManager.seekWithSlider(value: value) { [weak self] newPosition in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            
                            // Update position smoothly without flicker
                            self.currentLocation = newPosition
                            self.debouncedSaveLocation()
                            
                            // Allow UI updates again after brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                self.isWaitingForPlayer = false
                            }
                        }
                    }
                } else {
                    await self.legacyMove(to: value)
                    self.isWaitingForPlayer = false
                }
            } catch {
                await self.legacyMove(to: value)
                self.isWaitingForPlayer = false
            }
        }
    }
    
    // MARK: - UI Flicker Prevention
    
    @Published private var suppressUpdates: Bool = false
    private var suppressBackgroundProgressUpdates: Bool = false
    private var suppressionWorkItem: DispatchWorkItem?
    
    public func suppressBackgroundUpdates(_ suppress: Bool) {
        suppressBackgroundProgressUpdates = suppress
    }
    
    /// Set target progress immediately to prevent slider snap-back
    public func setTargetProgress(_ progress: Double) {
        // Set target progress for smooth UI transition
        targetProgress = progress
        playbackProgress = progress
        
        // Suppress background updates briefly to let seeking complete
        suppressProgressUpdates(for: 1.0)
    }
    
    private func suppressProgressUpdates(for duration: TimeInterval) {
        suppressionWorkItem?.cancel()
        suppressUpdates = true
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.suppressUpdates = false
        }
        suppressionWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
    
    // MARK: - Chapter Navigation Support
    
    /// Recalculates progress when navigating to a new chapter
    private func recalculateProgressForNewPosition(_ position: TrackPosition) {
        // When jumping to a new chapter via TOC, should start at beginning of chapter
        // Calculate the actual progress within the new chapter
        
        if let modernManager = audiobookManager as? DefaultAudiobookManager {
            let chapterProgress = modernManager.calculateChapterProgress(for: position)
            
            ATLog(.info, "🧭 Chapter navigation: Position \(position.track.key)@\(position.timestamp)s → progress \(chapterProgress)")
            
            // Force immediate UI update on main thread
            DispatchQueue.main.async { [weak self] in
                self?.playbackProgress = chapterProgress
                self?.targetProgress = chapterProgress
                ATLog(.info, "🧭 UI updated: playbackProgress = \(chapterProgress)")
            }
        } else {
            // Legacy fallback: start of chapter for TOC navigation
            DispatchQueue.main.async { [weak self] in
                self?.playbackProgress = 0.0
                self?.targetProgress = 0.0
                ATLog(.info, "🧭 Legacy: Reset progress to 0.0")
            }
        }
    }
    
    // MARK: - Performance Optimizations
    
    private func debouncedSaveLocation() {
        // Cancel previous save timer
        saveLocationWorkItem?.cancel()
        
        // Create new debounced save
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveLocation()
        }
        saveLocationWorkItem = workItem
        
        // Execute after delay to batch rapid seeks
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private var saveLocationWorkItem: DispatchWorkItem?
    
    @MainActor
    private func legacyMove(to value: Double) async {
        await withCheckedContinuation { continuation in
            self.audiobookManager.audiobook.player.move(to: value) { [weak self] adjustedLocation in
                self?.currentLocation = adjustedLocation
                self?.saveLocation()
                continuation.resume()
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
