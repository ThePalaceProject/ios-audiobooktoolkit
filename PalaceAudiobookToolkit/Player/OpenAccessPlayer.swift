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
    let avQueuePlayer: AVQueuePlayer = AVQueuePlayer()
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
    var currentTrackPosition: TrackPosition?
    var isLoaded: Bool = true
    var queuedTrackPosition: TrackPosition?
    
    var isDrmOk: Bool = true {
        didSet {
            if !isDrmOk {
                pause()
                playbackStatePublisher.send(.failed(currentTrackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil)))
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
    
    private var playerIsReady: AVPlayerItem.Status = .unknown {
        didSet {
            switch playerIsReady {
            case .readyToPlay:
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
        super.init()
        configurePlayer()
        addPlayerObservers()
    }
    
    private func configurePlayer() {
        buildPlayerQueue()
        setupAudioSession()
    }

    func play() {
        guard isLoaded,
              let firstTrack = tableOfContents.tracks.tracks.first else {
            playbackStatePublisher.send(.failed(currentTrackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil)))
            return
        }
        
        let trackPosition = currentTrackPosition ?? TrackPosition(track: firstTrack, timestamp: 0, tracks: tableOfContents.tracks)
        
        guard isDrmOk else {
            playbackStatePublisher.send(.failed(currentTrackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil)))
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
            playbackStatePublisher.send(.failed(trackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)))
            
            if self.avQueuePlayer.currentItem == nil {
                guard let task = self.currentTrackPosition?.track.downloadTask else {
                    playbackStatePublisher.send(.failed(trackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)))
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
                        break
//                        self.rebuildOnFinishedDownload(task: self.currentTrackPosition.tr.downloadTask)
                    default:
                        break
                    }
                }
            }
        case .failed:
            playbackStatePublisher.send(.failed(trackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.playerNotReady.rawValue, userInfo: nil)))
        }
    }
    
    func pause() {
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
    
    func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        seekTo(position: position) { [weak self] trackPosition in
            self?.avQueuePlayer.play()
            completion?(nil)
        }
    }
    
    func assetFileStatus(_ task: DownloadTask) -> AssetResult? {
        guard let task = task as? OpenAccessDownloadTask else {
            return nil
        }
        return task.assetFileStatus()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
        removePlayerObservers()
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
    
//    fileprivate func rebuildOnFinishedDownload(task: DownloadTask){
//        ATLog(.debug, "Added observer for missing download task.")
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.downloadTaskFinished),
//                                               name: taskCompleteNotification,
//                                               object: task)
//    }
//    
//    @objc func downloadTaskFinished() {
//        self.rebuildQueueAndSeekOrPlay(cursor: self.cursor, newOffset: self.queuedSeekOffset)
//        self.taskCompletion?(nil)
//        self.taskCompletion = nil
//        NotificationCenter.default.removeObserver(self, name: taskCompleteNotification, object: nil)
//    }
//    
//    func rebuildQueueAndSeekOrPlay(trackPosition: TrackPosition) {
//        buildNewPlayerQueue(atCursor: self.cursor) { (success) in
//            if success {
//                if let newOffset = newOffset {
//                    self.seekWithinCurrentItem(newOffset: newOffset)
//                } else {
//                    self.play()
//                }
//            } else {
//                ATLog(.error, "Ready status is \"failed\".")
//                let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
//                self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
//            }
//        }
//    }
        
}

extension OpenAccessPlayer {
    private func playbackBegan(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.started(trackPosition))
    }
    
    private func playbackStopped(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.stopped(trackPosition))
    }
    
    private func setupAudioSession() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption(_:)), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    private func addPlayerObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
        
        avQueuePlayer.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        avQueuePlayer.addObserver(self, forKeyPath: "rate", options: [.new, .old], context: nil)
    }
    
    @objc func playerItemDidReachEnd(_ notification: Notification) {
        // Advance to the next item or stop if at the end.
        // Notify delegates or publish a state change accordingly.
    }
    
    func removePlayerObservers() {
        NotificationCenter.default.removeObserver(self)
        avQueuePlayer.removeObserver(self, forKeyPath: "status")
        avQueuePlayer.removeObserver(self, forKeyPath: "rate")
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
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
    
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition else {
            completion?(nil)
            return
        }
        
        let newTimestamp = currentTrackPosition.timestamp + (timeInterval * 1000)
        let totalDuration = currentTrackPosition.track.duration
        
        if newTimestamp >= 0 && newTimestamp <= totalDuration {
            seekTo(position: TrackPosition(track: currentTrackPosition.track, timestamp: newTimestamp, tracks: currentTrackPosition.tracks), completion: completion)
        } else {
            handleBeyondCurrentTrackSkip(newTimestamp: newTimestamp, completion: completion)
        }
        
        func handleBeyondCurrentTrackSkip(newTimestamp: Double, completion: ((TrackPosition?) -> Void)?) {
            if newTimestamp > currentTrackPosition.track.duration {
                // Example of moving to the next track
                if let nextTrack = currentTrackPosition.tracks.nextTrack(currentTrackPosition.track) {
                    let overflowTime = newTimestamp - currentTrackPosition.track.duration
                    let newPosition = TrackPosition(track: nextTrack, timestamp: overflowTime, tracks: currentTrackPosition.tracks)
                    play(at: newPosition) { error in
                        completion?(newPosition)
                    }
                }
            } else if newTimestamp < 0 {
                if let previousTrack = currentTrackPosition.tracks.previousTrack(currentTrackPosition.track) {
                    let newPosition = TrackPosition(track: previousTrack, timestamp: previousTrack.duration + newTimestamp, tracks: currentTrackPosition.tracks)
                    play(at: newPosition) { error in
                        completion?(newPosition)
                    }
                }
            }
        }
        
        func move(to position: TrackPosition, completion: ((Error?) -> Void)?) {
            // Check if the move is within the current track or requires changing tracks
            if position.track.id == currentTrackPosition.track.id {
                // Seek within the current track
                seekTo(position: position, completion: { newTrackPosition in
                    completion?(nil)
                })
            } else {
                // Switch to the new track and seek to the desired position
                play(at: position) { error in
                    completion?(error)
                }
            }
        }
        
    }
    
    func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        let cmTime = CMTime(seconds: Double(position.timestamp) / 1000.0, preferredTimescale: CMTimeScale(1000))
        avQueuePlayer.seek(to: cmTime) { _ in
            self.currentTrackPosition = position
            completion?(position)
        }
    }
    
    private func buildPlayerQueue() {
        avQueuePlayer.removeAllItems()
        tableOfContents.toc.forEach { chapter in
            guard let url = (chapter.position.track as? OpenAccessTrack)?.url else { return }
            let playerItem = AVPlayerItem(url: url)
            avQueuePlayer.insert(playerItem, after: nil)
        }
    }

    @objc func advanceToNextPlayerItem(notification: Notification) {
        guard let currentTrackPosition else {
            return
        }
        
        defer {
            if let completedTrack = try? tableOfContents.chapter(forPosition: currentTrackPosition) {
                playbackStatePublisher.send(.completed(completedTrack))
            }
        }

        guard let nextTrack = self.tableOfContents.tracks.nextTrack(currentTrackPosition.track) else {
            ATLog(.debug, "End of book reached.")
            self.pause()
            
            return
        }

        self.avQueuePlayer.advanceToNextItem()
    }
}
