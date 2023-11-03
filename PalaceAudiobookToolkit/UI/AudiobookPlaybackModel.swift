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

class AudiobookPlaybackModel: ObservableObject, PlayerDelegate, AudiobookManagerTimerDelegate, AudiobookNetworkServiceDelegate {

    @ObservedObject private var reachability = Reachability()
    
    @Published var isWaitingForPlayer = false
    @Published var playbackProgress: Double = 0
    @Published var currentLocation: ChapterLocation? {
        didSet {
            playbackProgress = offset / duration
        }
    }
    
    let skipTimeInterval: TimeInterval = DefaultAudiobookManager.skipTimeInterval
    
    var offset: TimeInterval {
        self.currentLocation?.actualOffset ?? 0
    }
    var duration: TimeInterval {
        self.currentLocation?.duration ?? 0
    }
    var timeLeft: TimeInterval {
        max(duration - offset, 0)
    }
    var timeLeftInBook: TimeInterval {
        guard let currentLocation else {
            return 0
        }
        let spine = self.audiobookManager.audiobook.spine
        var addUpStuff = false
        let timeLeftInChapter = currentLocation.timeRemaining
        let timeLeftAfterChapter = spine.reduce(timeLeftInChapter, { (result, element) -> TimeInterval in
            var newResult: TimeInterval = 0
            if addUpStuff {
                newResult = result + element.chapter.duration
            }

            if element.chapter.inSameChapter(other: currentLocation) {
                newResult = timeLeftInChapter
                addUpStuff = true
            }
            return newResult
        })
        return timeLeftAfterChapter
    }
    
    @Published var isDownloading = false
    @Published var overallDownloadProgress: Float = 0
    @Published var spineErrors: [String: Error] = [:]
    @Published var coverImage: UIImage?
    
    private var subscriptions: Set<AnyCancellable> = []
    
    var isPlaying: Bool {
        audiobookManager.audiobook.player.isPlaying
    }
    
    var spine: [SpineElement] {
        audiobookManager.networkService.spine
    }

    private(set) var audiobookManager: AudiobookManager
        
    init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        self.currentLocation = audiobookManager.audiobook.spine.first?.chapter
        self.audiobookManager.audiobook.player.registerDelegate(self)
        self.audiobookManager.networkService.registerDelegate(self)
        self.audiobookManager.networkService.fetch()
        self.reachability.startMonitoring()
        self.reachability.$isConnected
            .receive(on: RunLoop.current)
            .sink { isConnected in
                if isConnected && self.overallDownloadProgress != 0 {
                    self.audiobookManager.networkService.fetch()
                }
            }
            .store(in: &subscriptions)
        self.audiobookManager.fetchBookmarks { _ in }
    }
    
    deinit {
        self.reachability.stopMonitoring()
        self.audiobookManager.timerDelegate = nil
        self.audiobookManager.audiobook.player.removeDelegate(self)
        self.audiobookManager.networkService.removeDelegate(self)
        self.audiobookManager.audiobook.player.unload()
    }
    
    func playPause() {
        self.audiobookManager.timerDelegate = self
        isWaitingForPlayer = true
        if isPlaying {
            audiobookManager.audiobook.player.pause()
        } else {
            audiobookManager.audiobook.player.play()
        }
        audiobookManager.saveLocation()
    }
    
    func stop() {
        audiobookManager.saveLocation()
        audiobookManager.audiobook.player.unload()
    }
    
    func skipBack() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else {
            return
        }
        isWaitingForPlayer = true
        audiobookManager.audiobook.player.skipPlayhead(-skipTimeInterval) { adjustedLocation in
            self.currentLocation = adjustedLocation
            self.audiobookManager.saveLocation()
        }
    }
    
    func skipForward() {
        guard !isWaitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else { return }
        isWaitingForPlayer = true
        audiobookManager.audiobook.player.skipPlayhead(skipTimeInterval) { adjustedLocation in
            self.currentLocation = adjustedLocation
            self.audiobookManager.saveLocation()
        }
    }
    
    func move(to value: Double) {
        let offset = duration * value
        guard let requestedOffset = self.currentLocation?.update(playheadOffset: offset),
        let currentOffset = self.currentLocation else {
            ATLog(.error, "Scrubber attempted to scrub without a current chapter.")
            return
        }
        self.isWaitingForPlayer = true
        let offsetMovement = requestedOffset.playheadOffset - currentOffset.actualOffset
        self.audiobookManager.audiobook.player.skipPlayhead(offsetMovement) { adjustedLocation in
            self.currentLocation = adjustedLocation
            self.audiobookManager.saveLocation()
        }
    }
    
    func setPlaybackRate(_ playbackRate: PlaybackRate) {
        audiobookManager.audiobook.player.playbackRate = playbackRate
    }
    
    func setSleepTimer(_ trigger: SleepTimerTriggerAt) {
        audiobookManager.sleepTimer.setTimerTo(trigger: trigger)
    }
    
    func addBookmark(completion: @escaping (_ error: Error?) -> Void) {
        audiobookManager.saveBookmark(completion: completion)
    }
    
    // MARK: - Player timer delegate
    
    func audiobookManager(_ audiobookManager: AudiobookManager, didUpdate timer: Timer?) {
        currentLocation = audiobookManager.audiobook.player.currentChapterLocation
    }
    
    // MARK: - PlayerDelegate
    
    func player(_ player: Player, didBeginPlaybackOf chapter: ChapterLocation) {
        currentLocation = audiobookManager.audiobook.player.currentChapterLocation
        isWaitingForPlayer = false
    }
    
    func player(_ player: Player, didStopPlaybackOf chapter: ChapterLocation) {
        currentLocation = audiobookManager.audiobook.player.currentChapterLocation
        isWaitingForPlayer = false
    }
    
    func player(_ player: Player, didComplete chapter: ChapterLocation) {
        isWaitingForPlayer = false
    }
    
    func player(_ player: Player, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?) {
        isWaitingForPlayer = false
    }
    
    func playerDidUnload(_ player: Player) {
        isWaitingForPlayer = false
    }
    
    // MARK: - AudiobookNetworkServiceDelegate
    
    func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didUpdateOverallDownloadProgress progress: Float) {
        overallDownloadProgress = progress
        isDownloading = progress < 1
    }
    
    func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didReceive error: NSError?, for spineElement: SpineElement) {
        spineErrors[spineElement.key] = error
        isDownloading = false
    }
    
    func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didUpdateProgressFor spineElement: SpineElement) {
        spineErrors.removeValue(forKey: spineElement.key)
    }
    
    func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didCompleteDownloadFor spineElement: SpineElement) {
        spineErrors.removeValue(forKey: spineElement.key)
    }
    
    func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didDeleteFileFor spineElement: SpineElement) {
        spineErrors.removeValue(forKey: spineElement.key)
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
