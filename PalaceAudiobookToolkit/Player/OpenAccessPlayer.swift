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
    
    var taskCompleteNotification: Notification.Name {
        return OpenAccessTaskCompleteNotification
    }
    
    var queuesEvents: Bool = false
    var taskCompletion: Completion? = nil
    var isLoaded: Bool = false
    var queuedTrackPosition: TrackPosition?
    
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
            if isPlaying {
                self.avQueuePlayer.rate = PlaybackRate.convert(rate: newValue)
                savePlaybackRate(rate: newValue)
            }
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
        print("Debugger: currentItem: \(currentItem)")

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
    private var lastKnownPosition: TrackPosition?
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
    
    private func configurePlayer() {
        setupAudioSession()
        buildPlayerQueue()
    }

    func play() {
        guard isLoaded, let firstTrack = tableOfContents.allTracks.first else {
            handlePlaybackError(.drmExpired)
            return
        }
        
        if !isDrmOk {
            handlePlaybackError(.drmExpired)
            return
        }
        
        let trackPosition = currentTrackPosition ?? TrackPosition(track: firstTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
        attemptToPlay(trackPosition)
    }
    
    private func handlePlaybackError(_ error: OpenAccessPlayerError) {
        playbackStatePublisher.send(.failed(currentTrackPosition, NSError(domain: errorDomain, code: error.rawValue)))
        unload()
    }
    
    private func attemptToPlay(_ trackPosition: TrackPosition) {
        switch playerIsReady {
        case .readyToPlay:
            avQueuePlayer.play()
            playbackStatePublisher.send(.started(trackPosition))
        default:
            handlePlaybackError(.playerNotReady)
        }
    }

    func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        seekTo(position: position) { [weak self] trackPosition in
            self?.avQueuePlayer.play()
            completion?(nil)
        }
    }
    
    func pause() {
        clearPositionCache()
        avQueuePlayer.pause()
        if let trackPosition = currentTrackPosition {
            playbackStatePublisher.send(.stopped(trackPosition))
        }
    }
    
    func unload() {
        avQueuePlayer.removeAllItems()
        isLoaded = false
        playbackStatePublisher.send(.unloaded)
        removePlayerObservers()
        cancellables.removeAll()
    }

    func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        guard let task = task as? OpenAccessDownloadTask else {
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
    
    private func listenForDownloadCompletion(task: DownloadTask? = nil) {
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
              case .saved(let urls) = fileStatus,
              !isPlaying else {
            return
        }
        
        if let currentAssetURL = (avQueuePlayer.currentItem?.asset as? AVURLAsset)?.url,
           urls.contains(currentAssetURL) {
            rebuildPlayerQueueAndNavigate(to: currentTrackPosition)
        } else if currentTrackPosition == nil && tableOfContents.allTracks.first?.id == track.id {
            buildPlayerQueue()
            print("Debugger: Building player queue for the first track.")
        }
    }
}

extension OpenAccessPlayer {
    private func playbackBegan(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.started(trackPosition))
    }
    
    private func playbackStopped(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.stopped(trackPosition))
    }
    
    private func setupAudioSession() {
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
        
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    private func addPlayerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: nil
        )
        
        avQueuePlayer.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        avQueuePlayer.addObserver(self, forKeyPath: "rate", options: [.new, .old], context: nil)
        isObservingPlayerStatus = true
    }

    @objc func playerItemDidReachEnd(_ notification: Notification) {
        guard let currentTrack = currentTrackPosition?.track,
            (tableOfContents.tracks.nextTrack(currentTrack) != nil)
        else {
            return
        }
        
        if let currentTrackPosition, let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) {
            playbackStatePublisher.send(.completed(currentChapter))
        }
        
        avQueuePlayer.advanceToNextItem()
    }
    
    func removePlayerObservers() {
        guard isObservingPlayerStatus else { return }
        NotificationCenter.default.removeObserver(self)
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
        if keyPath == "status", let player = object as? AVQueuePlayer {
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
    
    func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) else {
            completion?(currentTrackPosition)
            return
        }
        
        if let newPosition = try? currentChapter.position + value * (currentChapter.duration ?? 0.0) {
            seekTo(position: newPosition, completion: completion)
        } else {
            completion?(nil)
        }
    }

    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition ?? lastKnownPosition, 
        let newPosition = (try? currentTrackPosition + timeInterval) else {
            completion?(nil)
            return
        }
        
        seekTo(position: newPosition, completion: completion)
    }
    
    func handlePlaybackEnd(currentTrack: any Track, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition else {
            completion?(nil)
            return
        }

        let endPosition = TrackPosition(
            track: currentTrack,
            timestamp: currentTrack.duration,
            tracks: currentTrackPosition.tracks
        )
        
        if let completedChapter = try? tableOfContents.chapter(forPosition: endPosition) {
            playbackStatePublisher.send(.completed(completedChapter))
        }
        
        self.pause()
        ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
        completion?(endPosition)
    }
    
    func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
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
    
    private func rebuildPlayerQueueAndNavigate(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        avQueuePlayer.removeAllItems()
        let playerItems = buildPlayerItems()
        avQueuePlayer.items().forEach { avQueuePlayer.insert($0, after: nil) }
        
        navigateToPosition(position, in: playerItems, completion: completion)
    }
    
    private func navigateToPosition(_ position: TrackPosition, in items: [AVPlayerItem], completion: ((TrackPosition?) -> Void)?) {
        guard let index = items.firstIndex(where: { $0.trackIdentifier == position.track.key }) else {
            completion?(nil)
            return
        }
        
        let desiredItem = items[index]

        let wasPlaying = avQueuePlayer.rate > 0
        avQueuePlayer.pause()
        if avQueuePlayer.currentItem != desiredItem {
            avQueuePlayer.removeAllItems()
            avQueuePlayer.insert(desiredItem, after: nil)
            
            items.filter { $0 != desiredItem }.forEach { avQueuePlayer.insert($0, after: nil) }
            
            if wasPlaying {
                avQueuePlayer.play()
            }
        }
        
        let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: seekTime) { success in
            if success {
                completion?(position)
            } else {
                completion?(nil)
            }
        }
    }

    // Utilities and helpers
    private func buildPlayerItems() -> [AVPlayerItem] {
        return tableOfContents.allTracks.map { track in
            let url = track.urls!.first! // Simplified for example purposes
            let item = AVPlayerItem(url: url)
            item.trackIdentifier = track.key
            return item
        }
    }
    
    private func performSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        let cmTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: cmTime) { success in
            completion?(success ? position : nil)
        }
    }
 
    private func buildPlayerQueue() {
        resetPlayerQueue()
        
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.allTracks)
        if playerItems.isEmpty {
            isLoaded = false
            return
        }
        
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
            } else {
                isLoaded = avQueuePlayer.items().count > 0
                return
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        isLoaded = true
    }
    
    private func resetPlayerQueue() {
        for item in avQueuePlayer.items() {
            NotificationCenter.default.removeObserver(
                self, name: .AVPlayerItemDidPlayToEndTime,
                object: item
            )
        }
        avQueuePlayer.removeAllItems()
    }
    
    private func rebuildPlayerQueueAndNavigate(
        to trackPosition: TrackPosition?,
        completion: ((Bool) -> Void)? = nil
    ) {
        avQueuePlayer.removeAllItems()
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.allTracks)
        
        var desiredIndex: Int? = nil
        for (index, item) in playerItems.enumerated() {
            avQueuePlayer.insert(item, after: nil)
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
    
    private func navigateToItem(at index: Int, with timestamp: TimeInterval, completion: ((Bool) -> Void)? = nil) {
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
                self.avQueuePlayer.play()
                completion?(true)
            } else {
                completion?(false)
            }
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
    
    private func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
        var items = [AVPlayerItem]()
        for track in tracks {
            guard let fileStatus = assetFileStatus(track.downloadTask) else {
                continue
            }
            
            switch fileStatus {
            case .saved(let urls):
                for url in urls {
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.audioTimePitchAlgorithm = .timeDomain
                    playerItem.trackIdentifier = track.key
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
