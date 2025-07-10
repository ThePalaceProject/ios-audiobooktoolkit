//
//  OpenAccessPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/1/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import Combine

let AudioInterruptionNotification =  AVAudioSession.interruptionNotification
let AudioRouteChangeNotification =  AVAudioSession.routeChangeNotification

class OpenAccessPlayer: NSObject, Player {
    let avQueuePlayer: AVQueuePlayer
    var playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
    var tableOfContents: AudiobookTableOfContents
    var isPlaying: Bool {
        avQueuePlayer.rate != .zero
    }
    private var debounceWorkItem: DispatchWorkItem?
    
    var taskCompleteNotification: Notification.Name {
        return OpenAccessTaskCompleteNotification
    }
    
    var queuesEvents: Bool = false
    var taskCompletion: Completion? = nil
    var isLoaded: Bool = false
    var queuedTrackPosition: TrackPosition?

    var currentOffset: Double {
        currentTrackPosition?.timestamp ?? 0.0
    }

    var isDrmOk: Bool = true {
        didSet {
            if !isDrmOk {
                pause()
                playbackStatePublisher.send(
                    .failed(
                        currentTrackPosition,
                        NSError(
                            domain: errorDomain,
                            code: OpenAccessPlayerError.drmExpired.rawValue,
                            userInfo: nil
                        )
                    )
                )
                unload()
            }
        }
    }
    
    var playbackRate: PlaybackRate {
        set {
            self.avQueuePlayer.rate = PlaybackRate.convert(rate: newValue)
            savePlaybackRate(rate: newValue)
        }
        
        get {
            fetchPlaybackRate() ?? .normalTime
        }
    }
    
    var currentChapter: Chapter? {
        guard let currentTrackPosition else {
            return nil
        }
        
        return try? tableOfContents.chapter(forPosition: currentTrackPosition)
    }
    
    var currentTrackPosition: TrackPosition? {
        guard let currentItem = avQueuePlayer.currentItem,
              let currentTrack = tableOfContents.track(forKey: currentItem.trackIdentifier ?? "") else {
            return nil
        }
        
        let currentTime = currentItem.currentTime().seconds
        
        guard currentTime.isFinite else {
            return lastKnownPosition
        }
        
        let position = TrackPosition(
            track: currentTrack,
            timestamp: currentTime,
            tracks: tableOfContents.tracks
        )
        lastKnownPosition = position
        return position
    }
    
    private var cancellables = Set<AnyCancellable>()
    public var lastKnownPosition: TrackPosition?
    private var isObservingPlayerStatus = false
    
    private var playerIsReady: AVPlayerItem.Status = .readyToPlay {
        didSet {
            handlePlayerStatusChange()
        }
    }
    
    private var errorDomain: String {
        return OpenAccessPlayerErrorDomain
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        self.tableOfContents = tableOfContents
        self.avQueuePlayer = AVQueuePlayer()
        super.init()
        configurePlayer()
        addPlayerObservers()
    }
    
    func configurePlayer() {
        setupAudioSession()
        buildPlayerQueue()
    }
    
    private func handlePlaybackError(_ error: OpenAccessPlayerError) {
        playbackStatePublisher.send(.failed(currentTrackPosition, NSError(domain: errorDomain, code: error.rawValue)))
        unload()
    }
    
    private func attemptToPlay(_ trackPosition: TrackPosition) {
        switch playerIsReady {
        case .readyToPlay:
            avQueuePlayer.play()
            restorePlaybackRate()
            playbackStatePublisher.send(.started(trackPosition))
        default:
            handlePlaybackError(.playerNotReady)
        }
    }
    
    func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        ATLog(.debug, "[LCPDIAG] Attempting to play at position: \(position.track.key), timestamp: \(position.timestamp)")
        seekTo(position: position) { [weak self] trackPosition in
            guard let self = self else { return }
            if let item = self.avQueuePlayer.currentItem {
                ATLog(.debug, "[LCPDIAG] Current AVPlayerItem status: \(item.status.rawValue), error: \(String(describing: item.error))")
            }
            ATLog(.debug, "[LCPDIAG] Calling play() on AVQueuePlayer")
            self.avQueuePlayer.play()
            ATLog(.debug, "[LCPDIAG] AVQueuePlayer rate after play: \(self.avQueuePlayer.rate)")
            if let item = self.avQueuePlayer.currentItem {
                let duration = item.asset.duration.seconds
                let currentTime = item.currentTime().seconds
                ATLog(.debug, "[LCPDIAG] Current item duration: \(duration), current time: \(currentTime)")
            }
            self.restorePlaybackRate()
            completion?(nil)
        }
    }
    
    func play() {
        debouncePlayPauseAction {
            guard self.isLoaded, let currentTrackPosition = self.currentTrackPosition else {
                self.handlePlaybackError(.drmExpired)
                return
            }
            
            if !self.isDrmOk {
                self.handlePlaybackError(.drmExpired)
                return
            }
            
            self.attemptToPlay(currentTrackPosition)
            self.avQueuePlayer.rate = PlaybackRate.convert(rate: self.playbackRate)
        }
    }
    
    func pause() {
        debouncePlayPauseAction {
            self.clearPositionCache()
            self.avQueuePlayer.pause()
            if let trackPosition = self.currentTrackPosition {
                self.playbackStatePublisher.send(.stopped(trackPosition))
            }
        }
    }
    
    private func debouncePlayPauseAction(action: @escaping () -> Void) {
        debounceWorkItem?.cancel()
        debounceWorkItem = DispatchWorkItem { [weak self] in
            self?.synchronizedAccess(action)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: debounceWorkItem!)
    }
    
    private func synchronizedAccess(_ action: () -> Void) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        action()
    }
    
    func unload() {
        avQueuePlayer.removeAllItems()
        isLoaded = false
        playbackStatePublisher.send(.unloaded)
        removePlayerObservers()
        cancellables.removeAll()
    }
    
    func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        guard let task else {
            return nil
        }
        return task.assetFileStatus()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
        unload()
        removePlayerObservers()
        clearPositionCache()
    }
    
    func clearPositionCache() {
        lastKnownPosition = nil
    }
    
    private func handlePlayerStatusChange() {
        switch playerIsReady {
        case .readyToPlay:
            guard !isPlaying else { return }
            play()
            
        case .unknown:
            handleUnknownPlayerStatus()
            
        case .failed:
            ATLog(.error, "Player failed to load the media")
            
        default:
            break
        }
    }
    
    private func handleUnknownPlayerStatus() {
        guard self.avQueuePlayer.currentItem == nil else { return }
        
        if let fileStatus = assetFileStatus(self.currentTrackPosition?.track.downloadTask) {
            switch fileStatus {
            case .saved(let savedURLs):
                guard let item = createPlayerItem(files: savedURLs) else { return }
                
                if self.avQueuePlayer.canInsert(item, after: nil) {
                    self.avQueuePlayer.insert(item, after: nil)
                }
                
            case .missing:
                listenForDownloadCompletion()
                
            default:
                break
            }
        }
    }
    
    public func listenForDownloadCompletion(task: DownloadTask? = nil) {
        (task ?? self.currentTrackPosition?.track.downloadTask)?.statePublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    self.updatePlayerQueueIfNeeded()
                case .failure(let error):
                    ATLog(.error, "Download failed with error: \(error)")
                }
            }, receiveValue: { [weak self] state in
                if case .completed = state {
                    self?.updatePlayerQueueIfNeeded()
                }
            })
            .store(in: &self.cancellables)
    }
    
    private func updatePlayerQueueIfNeeded() {
        let trackToCheck = currentTrackPosition?.track ?? tableOfContents.allTracks.first
        
        guard let track = trackToCheck,
              let fileStatus = assetFileStatus(track.downloadTask),
              case .saved(let urls) = fileStatus else {
            return
        }
        
        if !isLoaded {
            if let currentAssetURL = (avQueuePlayer.currentItem?.asset as? AVURLAsset)?.url,
               urls.contains(currentAssetURL) {
                rebuildPlayerQueueAndNavigate(to: currentTrackPosition)
            } else if currentTrackPosition == nil || tableOfContents.allTracks.first?.id == track.id {
                buildPlayerQueue()
                if let firstTrack = tableOfContents.allTracks.first {
                    let firstTrackPosition = TrackPosition(track: firstTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
                    play(at: firstTrackPosition, completion: nil)
                }
            } else {
                rebuildPlayerQueueAndNavigate(to: currentTrackPosition)
            }
        }
    }
    
    public func buildPlayerQueue() {
        resetPlayerQueue()
        
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.allTracks)
        if playerItems.isEmpty {
            isLoaded = false
            return
        }
        
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
            } else {
                isLoaded = avQueuePlayer.items().count > 0
                return
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        isLoaded = true
    }
    
    public func rebuildPlayerQueueAndNavigate(
        to trackPosition: TrackPosition?,
        completion: ((Bool) -> Void)? = nil
    ) {
        resetPlayerQueue()
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.allTracks)
        
        var desiredIndex: Int? = nil
        for (index, item) in playerItems.enumerated() {
            avQueuePlayer.insert(item, after: nil)
            addEndObserver(for: item)
            if let trackPos = trackPosition, tableOfContents.allTracks[index].id == trackPos.track.id {
                desiredIndex = index
            }
        }
        
        guard let index = desiredIndex, index < playerItems.count else {
            completion?(false)
            return
        }
        
        navigateToItem(at: index, with: trackPosition?.timestamp ?? 0.0, completion: completion)
    }
    
    public func resetPlayerQueue() {
        for item in avQueuePlayer.items() {
            removeEndObserver(for: item)
        }
        avQueuePlayer.removeAllItems()
    }
    
    public func addEndObserver(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }
    
    public func removeEndObserver(for item: AVPlayerItem) {
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }
    
    public func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition ?? lastKnownPosition else {
            completion?(nil)
            return
        }
        
        let newPosition = currentTrackPosition + timeInterval
        seekTo(position: newPosition, completion: completion)
    }
    
    public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        if avQueuePlayer.currentItem?.trackIdentifier == position.track.key {
            performSeek(to: position, completion: completion)
        } else {
            if let _ = avQueuePlayer.items().first(where: { $0.trackIdentifier == position.track.key }) {
                navigateToPosition(position, in: avQueuePlayer.items(), completion: completion)
            } else {
                rebuildPlayerQueueAndNavigate(to: position) { success in
                    if success {
                        self.performSeek(to: position, completion: completion)
                    } else {
                        completion?(nil)
                    }
                }
            }
        }
    }
    
    public func navigateToItem(at index: Int, with timestamp: TimeInterval, completion: ((Bool) -> Void)? = nil) {
        let shouldPlay = avQueuePlayer.rate > 0
        
        avQueuePlayer.pause()
        
        for _ in 0..<index {
            avQueuePlayer.advanceToNextItem()
        }
        
        guard let currentItem = avQueuePlayer.currentItem else {
            completion?(false)
            return
        }
        
        let seekTime = CMTime(seconds: timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        currentItem.seek(to: seekTime) { success in
            if success {
                if shouldPlay {
                    self.avQueuePlayer.play()
                }

                self.restorePlaybackRate()
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }
    
    func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) else {
            completion?(currentTrackPosition)
            return
        }
        
        let newPosition = currentChapter.position + value * (currentChapter.duration ?? currentChapter.position.track.duration)
        seekTo(position: newPosition, completion: completion)
    }
    
    public func navigateToPosition(_ position: TrackPosition, in items: [AVPlayerItem], completion: ((TrackPosition?) -> Void)?) {
        guard let index = items.firstIndex(where: { $0.trackIdentifier == position.track.key }) else {
            completion?(nil)
            return
        }
        
        let shouldPlay = avQueuePlayer.rate > 0
        avQueuePlayer.pause()
        
        if avQueuePlayer.currentItem != items[index] {
            let currentIndex = items.firstIndex(where: { $0 == avQueuePlayer.currentItem }) ?? 0
            
            if index < currentIndex {
                rebuildPlayerQueueAndNavigate(to: position) { success in
                    completion?(position)
                }
            } else {
                for _ in currentIndex..<index {
                    avQueuePlayer.advanceToNextItem()
                }
            }
        }
        
        let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: seekTime) { success in
            if success && shouldPlay {
                self.avQueuePlayer.play()
            }
            self.restorePlaybackRate()

            DispatchQueue.main.async {
                completion?(success ? position : nil)
            }
        }
    }

    private func restorePlaybackRate() {
        avQueuePlayer.rate = PlaybackRate.convert(rate: playbackRate)
    }

    public func handlePlaybackEnd(currentTrack: any Track, completion: ((TrackPosition?) -> Void)?) {
        defer {
            if let currentTrackPosition, let firstTrack = currentTrackPosition.tracks.first {
                let endPosition = TrackPosition(
                    track: firstTrack,
                    timestamp: 0.0,
                    tracks: currentTrackPosition.tracks
                )

                avQueuePlayer.pause()
                rebuildPlayerQueueAndNavigate(to: endPosition)
                completion?(endPosition)
            }
        }

        ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
        playbackStatePublisher.send(.bookCompleted)
    }

}

extension OpenAccessPlayer {
    private func playbackBegan(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.started(trackPosition))
    }
    
    private func playbackStopped(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.stopped(trackPosition))
    }
    
    public func setupAudioSession() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance()
        )
        
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    public func addPlayerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance()
        )
        
        avQueuePlayer.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        avQueuePlayer.addObserver(self, forKeyPath: "rate", options: [.new, .old], context: nil)
        isObservingPlayerStatus = true
    }
    
    func removePlayerObservers() {
        guard isObservingPlayerStatus else { return }
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        avQueuePlayer.removeObserver(self, forKeyPath: "status")
        avQueuePlayer.removeObserver(self, forKeyPath: "rate")
        isObservingPlayerStatus = false
    }
    
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "status", let item = object as? AVPlayerItem {
            switch item.status {
            case .readyToPlay:
                ATLog(.debug, "[LCPDIAG] AVPlayerItem ready to play: \(item.trackIdentifier ?? "unknown")")
            case .failed:
                ATLog(.error, "[LCPDIAG] AVPlayerItem failed: \(item.trackIdentifier ?? "unknown"), error: \(String(describing: item.error))")
            case .unknown:
                ATLog(.debug, "[LCPDIAG] AVPlayerItem status unknown: \(item.trackIdentifier ?? "unknown")")
            @unknown default:
                ATLog(.debug, "[LCPDIAG] AVPlayerItem status unknown default: \(item.trackIdentifier ?? "unknown")")
            }
        } else if keyPath == "status", let player = object as? AVQueuePlayer {
            switch player.status {
            case .readyToPlay:
                playerIsReady = .readyToPlay
            case .failed:
                playerIsReady = .failed
            default:
                break
            }
        } else if keyPath == "rate", let player = object as? AVQueuePlayer {
            guard let rate = PlaybackRate(rawValue: Int(player.rate)) else { return }
            self.savePlaybackRate(rate: rate)
        }
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            ATLog(.warn, "System audio interruption began.")
        case .ended:
            ATLog(.warn, "System audio interruption ended.")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }
        default: ()
        }
    }
    
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue:reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            let session = AVAudioSession.sharedInstance()
            for output in session.currentRoute.outputs {
                switch output.portType {
                case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
                    play()
                default: ()
                }
            }
        case .oldDeviceUnavailable:
            if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                for output in previousRoute.outputs {
                    switch output.portType {
                    case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
                        pause()
                    default: ()
                    }
                }
            }
        default: ()
        }
    }
    
    public func performSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        let cmTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: cmTime) { success in
            completion?(success ? position : nil)
        }
    }
    
    private func createPlayerItem(files: [URL]) -> AVPlayerItem? {
        guard files.count > 1 else { return AVPlayerItem(url: files[0]) }
        
        let composition = AVMutableComposition()
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        
        do {
            for (index, file) in files.enumerated() {
                let asset = AVAsset(url: file)
                if index == files.count - 1 {
                    try compositionAudioTrack?.insertTimeRange(
                        CMTimeRangeMake(start: .zero,duration: asset.duration),
                        of: asset.tracks(withMediaType: .audio)[0],
                        at: compositionAudioTrack?.asset?.duration ?? .zero
                    )
                } else {
                    try compositionAudioTrack?.insertTimeRange(
                        CMTimeRangeMake(start: .zero, duration: asset.duration),
                        of: asset.tracks(withMediaType: .audio)[0],
                        at: compositionAudioTrack?.asset?.duration ?? .zero
                    )
                }
            }
        } catch {
            ATLog(.error, "Player not yet ready. QueuedToPlay = true.")
            return nil
        }
        
        return AVPlayerItem(asset: composition)
    }
    
    @objc func playerItemDidReachEnd(_ notification: Notification) {
        guard let currentTrack = currentTrackPosition?.track else {
            return
        }
        
        if let nextTrack = tableOfContents.tracks.nextTrack(currentTrack) {
            if let currentTrackPosition,
               let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) {
                playbackStatePublisher.send(.completed(currentChapter))
                
                if avQueuePlayer.items().count > nextTrack.index + 1 {
                    avQueuePlayer.advanceToNextItem()
                } else {
                    rebuildPlayerQueueAndNavigate(to: TrackPosition(track: nextTrack, timestamp: 0.0, tracks: currentTrackPosition.tracks))
                }
            }
        } else {
            handlePlaybackEnd(currentTrack: currentTrack, completion: nil)
        }
    }
    
    public func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
        var items = [AVPlayerItem]()
        for track in tracks {
            guard let fileStatus = assetFileStatus(track.downloadTask) else {
                continue
            }
            
            switch fileStatus {
            case .saved(let urls):
                for url in urls {
                    // [LCPDIAG] Log file existence and size
                    let fileExists = FileManager.default.fileExists(atPath: url.path)
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                    ATLog(.debug, "[LCPDIAG] Creating AVPlayerItem for track: \(track.key), url: \(url), exists: \(fileExists), size: \(fileSize)")
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.audioTimePitchAlgorithm = .timeDomain
                    playerItem.trackIdentifier = track.key
                    // [LCPDIAG] Observe status changes
                    playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
                    items.append(playerItem)
                }
            case .missing:
                listenForDownloadCompletion(task: track.downloadTask)
                continue
            case .unknown:
                continue
            }
        }
        return items
    }
}
