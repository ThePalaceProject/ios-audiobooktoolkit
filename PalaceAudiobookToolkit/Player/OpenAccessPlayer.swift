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

class OpenAccessPlayer: Player {
    let avQueuePlayer: AVQueuePlayer = AVQueuePlayer()
    var playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
    var tableOfContents: TableOfContents
    
    var isPlaying: Bool {
        avQueuePlayer.rate != .zero
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
    
    required init(tableOfContents: TableOfContents) {
        self.tableOfContents = tableOfContents
        configurePlayer()
        addPlayerObservers()
    }
    
    private func configurePlayer() {
        buildPlayerQueue()
        setupAudioSession()
    }
    
    func play() {
        guard isLoaded, let trackPosition = currentTrackPosition else {
            playbackStatePublisher.send(.failed(currentTrackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil)))
            return
        }
        
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
            playbackStatePublisher.send(.began(trackPosition))
            
        case .unknown:
            playbackStatePublisher.send(.failed(trackPosition, NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)))
            
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
    
    private func playbackBegan(trackPosition: TrackPosition) {
        playbackStatePublisher.send(.began(trackPosition))
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
        // Implement observing AVPlayerItem's status, AVQueuePlayer's rate, and other relevant properties to trigger state changes.
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
            } else {
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
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }
    
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition else {
            completion?(nil)
            return
        }
        
        let newTimestamp = currentTrackPosition.timestamp + Int(timeInterval * 1000)
        let totalDuration = currentTrackPosition.track.duration
        
        if newTimestamp >= 0 && newTimestamp <= totalDuration {
            seekTo(position: TrackPosition(track: currentTrackPosition.track, timestamp: newTimestamp, tracks: currentTrackPosition.tracks), completion: completion)
        } else {
            handleBeyondCurrentTrackSkip(newTimestamp: newTimestamp, completion: completion)
        }
        
        func handleBeyondCurrentTrackSkip(newTimestamp: Int, completion: ((TrackPosition?) -> Void)?) {
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
            if position.track == currentTrackPosition.track {
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
            guard let url = URL(string: chapter.position.track.href ?? "") else { return }
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
