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
                        NSError(domain: errorDomain,
                                code: OpenAccessPlayerError.drmExpired.rawValue,
                                userInfo: nil)
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
            }
        }
        
        get {
            fetchPlaybackRate() ?? .normalTime
        }
    }
    
    var currentTrackPosition: TrackPosition? {
        guard let currentItem = avQueuePlayer.currentItem,
              let currentTrack = tableOfContents.track(forKey: currentItem.trackIdentifier ?? "") else {
            print("DEBUGGING: Current item not found in the queue")
            return nil
        }
                
        let currentTime = currentItem.currentTime().seconds
        guard currentTime.isFinite else {
            print("DEBUGGING: Current time is infinite, likely due to transition or load issues")
            return lastKnownPosition
        }
        
        print("TimeTracking: AVQueuePlayer.currentTime: \(currentTime)")

        let position = TrackPosition(track: currentTrack, timestamp: currentTime, tracks: tableOfContents.tracks)
        lastKnownPosition = position
        print("TimeTracking: Current position: \(position.description)")
        return position
    }
    
    private var cancellables = Set<AnyCancellable>()
    private var lastKnownPosition: TrackPosition?

    var currentChapter: Chapter? {
        guard let currentTrackPosition else {
            return nil
        }

        return try? tableOfContents.chapter(forPosition: currentTrackPosition)
    }

    private var playerIsReady: AVPlayerItem.Status = .readyToPlay {
        didSet {
            switch playerIsReady {
            case .readyToPlay:
                guard !isPlaying else { return }
                self.play()
            case .failed:
                fallthrough
            case .unknown:
                break
            }
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
        clearPositionCache()

        guard isLoaded,
              let firstTrack = tableOfContents.tracks.tracks.first else {
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
            return
        }
        
        let trackPosition = currentTrackPosition ?? TrackPosition(track: firstTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
        
        guard isDrmOk else {
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
            return
        }
        
        switch playerIsReady {
        case .readyToPlay:

            avQueuePlayer.play()
            let rate = PlaybackRate.convert(rate: playbackRate)
            if avQueuePlayer.rate != rate {
                avQueuePlayer.rate = rate
            }
            playbackStatePublisher.send(.started(trackPosition))
            
        case .unknown:
            playbackStatePublisher.send(
                .failed(
                    trackPosition,
                    NSError(
                        domain: errorDomain,
                        code: OpenAccessPlayerError.unknown.rawValue,
                        userInfo: nil
                    )
                )
            )

            if self.avQueuePlayer.currentItem == nil {
                guard let task = self.currentTrackPosition?.track.downloadTask else {
                    playbackStatePublisher.send(
                        .failed(
                            trackPosition, 
                            NSError(
                                domain: errorDomain,
                                code: OpenAccessPlayerError.unknown.rawValue,
                                userInfo: nil
                            )
                        )
                    )
                    return
                }
    
                if let fileStatus = assetFileStatus(task) {
                    switch fileStatus {
                    case .saved(let savedURLs):
                        let item = createPlayerItem(files: savedURLs) ?? AVPlayerItem(url: savedURLs[0])
                        
                        if self.avQueuePlayer.canInsert(item, after: nil) {
                            self.avQueuePlayer.insert(item, after: nil)
                        }
                    case .missing(_):
                        self.currentTrackPosition?.track.downloadTask?.statePublisher
                            .receive(on: DispatchQueue.main)
                            .sink(
                                receiveCompletion: { [weak self] completion in
                                    guard let self = self else { return }
                                    switch completion {
                                    case .finished:
                                        self.buildPlayerQueue()
                                    case .failure(let error):
                                        self.playbackStatePublisher.send(
                                            .failed(trackPosition,
                                                    NSError(domain: self.errorDomain,
                                                            code: OpenAccessPlayerError.downloadNotFinished.rawValue,
                                                            userInfo: ["message": "Download failed: \(error.localizedDescription)"])
                                                   )
                                        )
                                    }
                                },
                                receiveValue: { [weak self] downloadState in
                                    guard let self = self else { return }
                                    self.handleDownloadState(downloadState, trackPosition: trackPosition)
                                }
                            )
                            .store(in: &cancellables)
                    default:
                        break
                    }
                }
            }
        case .failed:
            playbackStatePublisher.send(
                .failed(trackPosition,
                        NSError(domain: errorDomain,
                                code: OpenAccessPlayerError.playerNotReady.rawValue,
                                userInfo: nil
                               )
                       )
            )
        }
    }
    
    private func handleDownloadState(_ downloadState: DownloadTaskState, trackPosition: TrackPosition) {
        switch downloadState {
        case .completed:
            // Rebuild queue now that download is complete
            self.buildPlayerQueue()
            DispatchQueue.main.async {
                self.avQueuePlayer.play()
            }
            playbackStatePublisher.send(.started(trackPosition))
        case .error(let error):
            // Notify that the playback failed due to download error
            playbackStatePublisher.send(
                .failed(trackPosition,
                        NSError(domain: errorDomain,
                                code: OpenAccessPlayerError.downloadNotFinished.rawValue,
                                userInfo: ["message": "Download failed: \(error?.localizedDescription)"])
                       )
            )
        default:
            print("Download state updated to \(downloadState)")
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
        NotificationCenter.default.removeObserver(self)
        avQueuePlayer.removeObserver(self, forKeyPath: "status")
        avQueuePlayer.removeObserver(self, forKeyPath: "rate")
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
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition)
        else { return }
    
        let newTimestamp = value * (currentChapter.duration ?? 0.0)
        seekTo(position: TrackPosition(
            track: currentTrackPosition.track,
            timestamp: newTimestamp,
            tracks: currentTrackPosition.tracks
        ),completion: completion)
    }
    
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition else {
            completion?(nil)
            return
        }
        
        let newTimestamp = currentTrackPosition.timestamp + timeInterval
        let totalDuration = currentTrackPosition.track.duration
        
        if newTimestamp >= 0 && newTimestamp <= totalDuration {
            seekTo(position: TrackPosition(
                track: currentTrackPosition.track,
                timestamp: newTimestamp,
                tracks: currentTrackPosition.tracks
            ), completion: completion)
        } else {
            handleBeyondCurrentTrackSkip(newTimestamp: newTimestamp, completion: completion)
        }
    
        func handleBeyondCurrentTrackSkip(newTimestamp: Double, completion: ((TrackPosition?) -> Void)?) {
            // Adjust to the next track if the timestamp exceeds the current track's duration.
            if newTimestamp > currentTrackPosition.track.duration {
                moveToNextTrackOrEnd(newTimestamp: newTimestamp, completion: completion)
            }
            // Adjust to the previous track if the timestamp is negative.
            else if newTimestamp < 0 {
                moveToPreviousTrackOrStart(newTimestamp: newTimestamp, completion: completion)
            }
            // Remain within `the current track, resetting to start if negative.
            else {
                let newPosition = TrackPosition(
                    track: currentTrackPosition.track,
                    timestamp: max(0, newTimestamp),
                    tracks: currentTrackPosition.tracks
                )
                play(at: newPosition) { error in
                    completion?(newPosition)
                }
            }
        }

        func moveToNextTrackOrEnd(newTimestamp: Double, completion: ((TrackPosition?) -> Void)?) {
            var currentTrack = currentTrackPosition.track
            let overflowTime = newTimestamp - currentTrack.duration
            
            if let nextTrack = currentTrackPosition.tracks.nextTrack(currentTrack) {
                currentTrack = nextTrack
                avQueuePlayer.advanceToNextItem()
                let newPosiiton = TrackPosition(track: nextTrack, timestamp: overflowTime, tracks: currentTrackPosition.tracks)
                seekTo(position: newPosiiton, completion: completion)
                print("DEBUGGING: advance to next item avQueuePlayer: \(avQueuePlayer.items().count)")
            } else {
                let endPosition = TrackPosition(
                    track: currentTrack,
                    timestamp: currentTrack.duration,
                    tracks: currentTrackPosition.tracks
                )
                
                if let completedTrack = try? tableOfContents.chapter(forPosition: endPosition) {
                    playbackStatePublisher.send(.completed(completedTrack))
                }
                
                self.pause()
                ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
                completion?(endPosition)
            }
        }
        
        func moveToPreviousTrackOrStart(newTimestamp: Double, completion: ((TrackPosition?) -> Void)?) {
            var adjustedTimestamp = newTimestamp
            var currentTrack = currentTrackPosition.track
            
            while adjustedTimestamp < 0 {
                guard let previousTrack = currentTrackPosition.tracks.previousTrack(currentTrack) else {
                    let newPosition = TrackPosition(
                        track: currentTrack,
                        timestamp: 0,
                        tracks: currentTrackPosition.tracks
                    )
                    self.play(at: newPosition) { error in
                        completion?(newPosition)
                    }
                    return
                }
                currentTrack = previousTrack
                adjustedTimestamp += currentTrack.duration
            }
            
            adjustedTimestamp = min(adjustedTimestamp, currentTrack.duration)
            
            let newPosition = TrackPosition(
                track: currentTrack,
                timestamp: adjustedTimestamp,
                tracks: currentTrackPosition.tracks
            )

            rebuildPlayerQueueAndNavigate(to: newPosition) { _ in
                completion?(newPosition)
            }
        }

        func move(to position: TrackPosition, completion: ((Error?) -> Void)?) {
            // Check if the move is within the current track or requires changing tracks
            if position.track.id == currentTrackPosition.track.id {
                seekTo(position: position, completion: { newTrackPosition in
                    completion?(nil)
                })
            } else {
                play(at: position) { error in
                    completion?(error)
                }
            }
        }
    }
    
    func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        let trackDuration = position.track.duration
                
        guard position.timestamp <= trackDuration else {
            ATLog(.error, "Seeking to an invalid position: \(position.timestamp) exceeds track duration \(trackDuration)")
            completion?(nil)
            return
        }
        
        if avQueuePlayer.status != .readyToPlay {
            ATLog(.error, "Player is not ready to play.")
            completion?(nil)
            return
        }
        
        let cmTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        print("DEBUGGING: seeking avQueuePlayer: \(avQueuePlayer.items().count)")

        avQueuePlayer.seek(to: cmTime) { success in
            if success {
                ATLog(.info, "Seek successful to time: \(position.timestamp)")
                completion?(position)
            } else {
                ATLog(.error, "Failed to seek to time: \(position.timestamp)")
                completion?(nil)
            }
        }
    }

    private func buildPlayerQueue() {
        for item in avQueuePlayer.items() {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        avQueuePlayer.removeAllItems()
        
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.tracks.tracks)
        if playerItems.isEmpty {
            isLoaded = false
            print("DEBUGGING: No items were queued. Loading failed.")
            return
        }
        
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
            } else {
                print("DEBUGGING: Cannot insert item \(item). Only partially complete queue.")
                isLoaded = avQueuePlayer.items().count > 0
                return
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        isLoaded = true
        print("DEBUGGING: newly built player avQueuePlayer: \(avQueuePlayer.items().count)")
    }
    
    private func rebuildPlayerQueueAndNavigate(to trackPosition: TrackPosition?, completion: @escaping (Bool) -> Void) {
        avQueuePlayer.removeAllItems()
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.tracks.tracks)
        
        var desiredIndex: Int? = nil
        for (index, item) in playerItems.enumerated() {
            avQueuePlayer.insert(item, after: nil)
            if let trackPos = trackPosition, tableOfContents.tracks.tracks[index].id == trackPos.track.id {
                desiredIndex = index
            }
        }
        
        guard let index = desiredIndex, index < playerItems.count else {
            completion(false)
            return
        }
        
        navigateToItem(at: index, with: trackPosition?.timestamp ?? 0.0, completion: completion)
    }
    
    private func navigateToItem(at index: Int, with timestamp: TimeInterval, completion: @escaping (Bool) -> Void) {
        avQueuePlayer.pause()
        
        for _ in 0..<index {
            avQueuePlayer.advanceToNextItem()
        }
        
        guard let currentItem = avQueuePlayer.currentItem else {
            completion(false)
            return
        }
        
        let seekTime = CMTime(seconds: timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        currentItem.seek(to: seekTime) { success in
            if success {
                self.avQueuePlayer.play()
                print("Navigated to \(index) and seeking to \(timestamp)")
                completion(true)
            } else {
                print("Failed to seek to \(timestamp) on item at \(index)")
                completion(false)
            }
        }
    }

    private func createPlayerItem(files: [URL]) -> AVPlayerItem? {
        guard files.count > 1 else { return AVPlayerItem(url: files[0]) }
        
        let composition = AVMutableComposition()
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        
        do {
            for (index, file) in files.enumerated() {
                let asset = AVAsset(url: file)
                if index == files.count - 1 {
                    try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: asset.tracks(withMediaType: .audio)[0], at: compositionAudioTrack?.asset?.duration ?? .zero)
                } else {
                    try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: asset.tracks(withMediaType: .audio)[0], at: compositionAudioTrack?.asset?.duration ?? .zero)
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
                print("DEBUGGING: No file status available, skipping track.")
                continue
            }
            
            switch fileStatus {
            case .saved(let urls):
                for url in urls {
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.audioTimePitchAlgorithm = .timeDomain
                    playerItem.trackIdentifier = track.key
                    items.append(playerItem)
                    print("DEBUGGING: Added track from URL: \(url)")
                }
            case .missing(_), .unknown:
                print("DEBUGGING: Track missing or status unknown, skipping.")
                continue
            }
        }
        return items
    }
}
