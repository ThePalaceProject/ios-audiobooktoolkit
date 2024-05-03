////
////  FindawayPlayer.swift
////  NYPLAudiobookToolkit
////
////  Created by Dean Silfen on 1/31/18.
////  Copyright © 2018 Dean Silfen. All rights reserved.
////
//
//import UIKit
//import AudioEngine
//import Combine
//
//typealias EngineManipulation = () -> Void
//typealias FindawayPlayheadManipulation = (previous: TrackPosition?, destination:TrackPosition)
//
//
///// `PlayerState`s help determine which methods to call
///// on the `FAEPlaybackEngine`. `PlayerState`s are set
///// by the public `play`/`skip`/`pause` methods defined
///// in the player interface. 
/////
///// The only method that ought to play or seek in a chapter
///// is `playWithCurrentState`, and it will check for the current
///// action and determine the way to handle its playback.
//enum PlayerState {
//    case none
//    case queued(FindawayPlayheadManipulation)
//    case play(FindawayPlayheadManipulation)
//    case paused(TrackPosition)
//}
//
//enum FindawayPlayerError {
//    case noAvailableTracks
//}
//
//final class FindawayPlayer: NSObject, Player {
//    var playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
//    var queuesEvents: Bool = true
//    var isDrmOk: Bool = true
//    var tableOfContents: AudiobookTableOfContents
//    var currentChapter: Chapter?
//    var isLoaded: Bool = true
//    
//    private var readyForPlayback: Bool = false
//    private var queuedPlayerState: PlayerState = .none
//    private let audioPlaybackRateIdentifierKey = "audioPlaybackRateKey"
//    private var audioEngine = FAEAudioEngine.shared()
//    private var cancellables: Set<AnyCancellable> = []
//
//    // `queuedEngineManipulation` is a closure that will manipulate
//    // `FAEPlaybackEngine`.
//    //
//    // The reason to queue a manipulation is that they are potentially
//    // very expensive, so by performing fewer manipulations, we get
//    // better performance and avoid crashes while in the background.
//    private var queuedEngineManipulation: EngineManipulation?
//
//    // `shouldPauseWhenPlaybackResumes` handles a case in the
//    // FAEPlaybackEngine where `pause`es that happen while
//    // the book is not playing are ignored. So if we are
//    // loading the next chapter for playback and a consumer
//    // decides to pause, we will fail.
//    //
//    // This flag is used to show that we intend to pause
//    // and it ought be checked when playback initiated
//    // notifications come in from FAEPlaybackEngine.
//    private var shouldPauseWhenPlaybackResumes = false
//    private var willBeReadyToPerformPlayheadManipulation: Date = Date()
//    private var debounceBufferTime: TimeInterval = 0.50
//
//    private var sessionKey: String {
//        self.tableOfContents.sessionKey ?? ""
//    }
//
//    private var licenseID: String {
//        self.tableOfContents.licenseID ?? ""
//    }
//
//    private var audiobookID: String {
//        return self.tableOfContents.tracks.audiobookID
//    }
//
//    /// If no book is loaded, AudioEngine returns 0, so this is consistent with their behavior
//    private var currentOffset: UInt {
//        audioEngine?.playbackEngine?.currentOffset ?? 0
//    }
//
//    var isPlaying: Bool {
//        audioEngine?.playbackEngine?.playerStatus == FAEPlayerStatus.playing
//    }
//    
////    var currentTrackPosition: TrackPosition? {
////        guard let currentChapter = audioEngine?.playbackEngine?.currentLoadedChapter(),
////              let currentOffset = audioEngine?
////              let currentTrack = tableOfContents.track(forKey: currentItem.trackIdentifier ?? "") else {
////            return nil
////        }
////        
////        let currentTime = currentItem.currentTime().seconds
////        guard currentTime.isFinite else {
////            return lastKnownPosition
////        }
////        
////        let position = TrackPosition(
////            track: currentTrack,
////            timestamp: currentTime,
////            tracks: tableOfContents.tracks
////        )
////        lastKnownPosition = position
////        return position
////    }
//    public var currentTrackPosition: TrackPosition? {
//        var position: TrackPosition?
//        if let queuedPosition = self.queuedPlayhead() {
//            position = queuedPosition
//        } else {
//            
//            guard let currentChapter = audioEngine?.playbackEngine?.currentLoadedChapter(),
//                  let currentTrack = tableOfContents.tracks.track(
//                    forPart: Int(currentChapter.partNumber),
//                    sequence: Int(currentChapter.chapterNumber))
//            else {
//                return nil
//            }
//
//            position = TrackPosition(
//                track: currentTrack,
//                timestamp: Double(self.currentOffset),
//                tracks: self.tableOfContents.tracks
//            )
//        }
//    
//        return position
//    }
//
//    private var bookIsLoaded: Bool {
//        guard audioEngine?.playbackEngine?.playerStatus != FAEPlayerStatus.unloaded else {
//            return false
//        }
//        let chapter = audioEngine?.playbackEngine?.currentLoadedChapter()
//        guard let loadedAudiobookID = chapter?.audiobookID else {
//            return false
//        }
//        return loadedAudiobookID == self.audiobookID
//    }
//
//    private var eventHandler: FindawayPlaybackNotificationHandler
//    private var queue = DispatchQueue(label: "org.nypl.labs.PalaceAudiobookToolkit.FindawayPlayer")
//    
//    convenience init?(tableOfContents: AudiobookTableOfContents) {
//        guard let firstTrack = tableOfContents.allTracks.first else {
//            return nil
//        }
//    
//        self.init(
//            currentPosition: TrackPosition(
//                track: firstTrack,
//                timestamp: 0,
//                tracks: tableOfContents.tracks
//            ), tableOfContents: tableOfContents
//        )
//    }
//
//    public init(currentPosition: TrackPosition,
//                tableOfContents: AudiobookTableOfContents,
//                eventHandler: FindawayPlaybackNotificationHandler = DefaultFindawayPlaybackNotificationHandler(),
//                databaseVerification: FindawayDatabaseVerification = FindawayDatabaseVerification.shared
//    ) {
//        self.isDrmOk = true
//        self.isLoaded = true
//        self.queuesEvents = true
//        self.queuedPlayerState = .paused(currentPosition)
//
//        self.eventHandler = eventHandler
//        self.readyForPlayback = databaseVerification.verified
//        self.tableOfContents = tableOfContents
//        super.init()
//
//        self.eventHandler.delegate = self
//        databaseVerification.registerDelegate(self)
//    }
//    
//    var playbackRate: PlaybackRate {
//      get {
//        let cachedValue = UserDefaults.standard.double(forKey: audioPlaybackRateIdentifierKey)
//        guard cachedValue != 0 else {
//          if let value = audioEngine?.playbackEngine?.currentRate {
//            return PlaybackRate(rawValue: Int(value * 100))!
//          } else {
//            return .normalTime
//          }
//        }
//        
//        audioEngine?.playbackEngine?.currentRate = Float(cachedValue)
//        return PlaybackRate(rawValue: Int(cachedValue * 100))!
//      }
//      
//      set(newRate) {
//          UserDefaults.standard.setValue(PlaybackRate.convert(rate: newRate), forKey: audioPlaybackRateIdentifierKey)
//        self.queue.sync {
//          ATLog(.debug, "FindawayPlayer: Setting playback rate to \(PlaybackRate.convert(rate: newRate))")
//          audioEngine?.playbackEngine?.currentRate = PlaybackRate.convert(rate: newRate)
//        }
//      }
//    }
//
//    func play() {
//        self.queue.async { [weak self] in
//            guard let self = self, self.readyForPlayback else {
//                ATLog(.error, "Player is not ready")
//                return
//            }
//            self.performPlay()
//        }
//    }
//
//    func pause() {
//        self.queue.async { [weak self] in
//            self?.performPause()
//        }
//    }
//    
//    func unload() {
//        audioEngine?.playbackEngine?.unload()
//        self.isLoaded = false
//        self.playbackStatePublisher.send(.unloaded)
//    }
//
//    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
//        self.queue.async { [weak self] in
//            guard let self = self, let currentTrackPosition = self.currentTrackPosition else {
//                ATLog(.error, "Invalid chapter information required for skip.")
//                DispatchQueue.main.async {
//                    completion?(nil)
//                }
//                return
//            }
//            let newTimestamp = currentTrackPosition.timestamp + timeInterval
//            let newPosition = TrackPosition(track: currentTrackPosition.track, timestamp: newTimestamp, tracks: currentTrackPosition.tracks)
//            self.move(to: newPosition) { position in
//                DispatchQueue.main.async {
//                    completion?(position)
//                }
//            }
//        }
//    }
//
////    func play(at position: TrackPosition, completion: (((any Error)?) -> Void)?) {
////        self.queue.async { [weak self] in
////            self?.performJumpToLocation(location)
////        }
////        completion?(nil)
////    }
//    func play(at position: TrackPosition, completion: (((Error?) -> Void)?) = nil) {
//        self.queue.async { [weak self] in
//            self?.move(to: position) { newPosition in
//                guard newPosition != nil else {
//                    completion?(NSError(domain: "PlayerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to move to new position."]))
//                    return
//                }
//                
//                self?.performJumpToLocation(position)
//                completion?(nil)
//            }
//        }
//    }
//    
//    func move(to value: Double, completion: ((TrackPosition?) -> Void)?) { /* NO OP */ }
//    
//    func move(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
//        self.queue.async { [weak self] in
//            _ = self?.performMoveToPosition(position)
//            self?.playbackStatePublisher.send(.stopped(position))
//        }
//        completion?(position)
//    }
//    
//    private func performMoveToPosition(_ position: TrackPosition) -> FindawayPlayheadManipulation {
//        let manipulation = self.createManipulation(position)
//        self.queuedPlayerState = .queued(manipulation)
//        return manipulation
//    }
////        self.queue.async { [weak self] in
////            guard let self = self,
////                  let currentTrackPosition = self.currentTrackPosition
////            else {
////                DispatchQueue.main.async {
////                    completion?(nil)
////                }
////                return
////            }
////
////            self.playbackStatePublisher.send(.started(position))
////            self.audioEngine?.playbackEngine.seek(to: position.timestamp) { success in
////                DispatchQueue.main.async {
////                    if success {
////                        completion?(position)
////                    } else {
////                        completion?(nil)
////                    }
////                }
////            }
////        }
////    }
//
//    private func queuedPlayhead() -> TrackPosition? {
//        switch self.queuedPlayerState {
//        case .none:
//            return nil
//        case .paused(let position),
//            .queued((_, let position)),
//            .play((_, let position)):
//            return position
//        }
//    }
//
//    private func performPlay() {
//        switch self.queuedPlayerState {
//        case .none:
//            if var position = self.currentTrackPosition {
//                position.timestamp = 0
//                self.queuedPlayerState = .play((previous: nil, destination: position))
//            }
//        case .queued(let manipulation):
//            self.queuedPlayerState = .play(manipulation)
//        case .paused(_):
//            fallthrough
//        case .play(_):
//            break
//        }
//        self.playWithCurrentState()
//    }
//    
//    private func performPause() {
//        guard let position = self.currentTrackPosition else {
//            return
//        }
//
//        if self.isPlaying {
//            self.queuedPlayerState = .paused(position)
//            audioEngine?.playbackEngine?.pause()
//            if let currentTrackPosition = self.currentTrackPosition {
//                self.playbackStatePublisher.send(.stopped(currentTrackPosition))
//            }
//        } else {
//            self.shouldPauseWhenPlaybackResumes = true
//        }
//    }
//    
//    private func performJumpToLocation(_ position: TrackPosition) {
//        if self.readyForPlayback {
//            self.queuedPlayerState = .play(self.createManipulation(position))
//            self.playWithCurrentState()
//        } else {
//            self.queuedPlayerState = .play((previous: nil, destination: position))
//        }
//    }
//
//    func createManipulation(_ position: TrackPosition) -> FindawayPlayheadManipulation {
//        let playheadBeforeManipulation = self.currentTrackPosition
////        let playhead = move(to: self.currentTrackPosition, completion: position)
//        return (previous: playheadBeforeManipulation, destination: position)
//    }
//
//
//    /// Method to determine which AudioEngine SDK should be called
//    /// to move the playhead or resume playback.
//    ///
//    /// Not all playhead movement costs the same. In order to ensure snappy and consistent
//    /// behavior from FAEPlaybackEngine, we must be careful about how many calls we make to
//    /// `[FAEPlaybackEngine playForAudiobookID:partNumber:chapterNumber:offset:sessionKey:licenseID]`.
//    /// Meanwhile, calls to `[FAEPlaybackEngine setCurrentOffset]` are cheap and can be made repeatedly.
//    /// Because of this we must determine what kind of request we have received before proceeding.
//    ///
//    /// If moving the playhead stays in the same file, then the update is instant and we are still
//    /// ready to get a new request.
//    private func playWithCurrentState() {
//        func seekOperation(_ positionBeforeNavigation: TrackPosition?, _ destinationPosition: TrackPosition) -> Bool {
//            return self.bookIsLoaded &&
//                self.isPlaying &&
//                destinationPosition == positionBeforeNavigation
//        }
//
//        /// We queue the playhead move in order to rate limit the expensive
//        /// move operation.
//        func enqueueEngineManipulation() {
//            func attemptToPerformQueuedEngineManipulation() {
//                guard let manipulationClosure = self.queuedEngineManipulation else {
//                    return
//                }
//                if Date() < self.willBeReadyToPerformPlayheadManipulation {
//                    enqueueEngineManipulation()
//                } else {
//                    manipulationClosure()
//                    
//                    self.queuedEngineManipulation = nil
//                    self.queuedPlayerState = .none
//                }
//            }
//            
//            self.queue.asyncAfter(deadline: self.dispatchDeadline()) {
//                attemptToPerformQueuedEngineManipulation()
//            }
//        }
//
//        func setAndQueueEngineManipulation(manipulationClosure: @escaping EngineManipulation) {
//            self.willBeReadyToPerformPlayheadManipulation = Date().addingTimeInterval(self.debounceBufferTime)
//            self.queuedEngineManipulation = manipulationClosure
//            enqueueEngineManipulation()
//        }
//
//        switch self.queuedPlayerState {
//        case .none:
//            break
//        case .queued((_, _)):
//            break
//        case .paused(let position) where !self.bookIsLoaded:
//            setAndQueueEngineManipulation { [weak self] in
//                self?.loadAndRequestPlayback(position)
//            }
//        case .paused:
//            setAndQueueEngineManipulation {
//                self.audioEngine?.playbackEngine?.resume()
//            }
//        case .play((let previous, let position)) where seekOperation(previous, position):
//            setAndQueueEngineManipulation { [weak self] in
//                self?.loadAndRequestPlayback(position)
//            }
//        case .play((_, let position)):
//            setAndQueueEngineManipulation { [weak self] in
//                self?.loadAndRequestPlayback(position)
//            }
//        }
//    }
//
//    private func loadAndRequestPlayback(_ position: TrackPosition) {
//        guard let track = position.track as? FindawayTrack else { return }
//
//        audioEngine?.playbackEngine?.play(
//            forAudiobookID: self.audiobookID,
//            partNumber: UInt(track.partNumber),
//            chapterNumber: UInt(track.chapterNumber),
//            offset: UInt(position.timestamp),
//            sessionKey: self.sessionKey,
//            licenseID: self.licenseID
//        )
//    }
//
//    private func dispatchDeadline() -> DispatchTime {
//        return DispatchTime.now() + self.debounceBufferTime
//    }
//}
//
//extension FindawayPlayer: FindawayDatabaseVerificationDelegate {
//    func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification) {
//        func handleLifecycleManagerUpdate(hasBeenVerified: Bool) {
//            self.readyForPlayback = hasBeenVerified
//            self.playWithCurrentState()
//        }
//
//        self.queue.async {
//            handleLifecycleManagerUpdate(hasBeenVerified: findawayDatabaseVerification.verified)
//        }
//    }
//}
//
//extension FindawayPlayer: FindawayPlaybackNotificationHandlerDelegate {
//
////    private func chapterLocation(FAEDescription chapter: FAEChapterDescription) -> ChapterLocation? {
////        let chapterLocation = self.cursor.data.first { (spineElement) -> Bool in
////            spineElement.chapter.number == chapter.chapterNumber && spineElement.chapter.part == chapter.partNumber
////            }?.chapter
////        guard let duration = chapterLocation?.duration else {
////            return nil
////        }
////        guard let newLocation = chapterLocation?.update(playheadOffset: duration) else {
////            return nil
////        }
////        return newLocation
////    }
//    private func chapter(for findawayChapter: FAEChapterDescription) -> Chapter? {
//        guard let track = tableOfContents.tracks.track(forPart: Int(findawayChapter.partNumber), sequence: Int(findawayChapter.chapterNumber)) else {
//            return nil
//        }
//        
//        return try? tableOfContents.chapter(forPosition: TrackPosition(track: track, timestamp: 0.0, tracks: tableOfContents.tracks))
//    }
//
//
//    func audioEnginePlaybackFinished(_ notificationHandler: FindawayPlaybackNotificationHandler, for chapter: FAEChapterDescription) {
//        guard let chapterAtEnd = self.chapter(for: chapter) else { return }
//        DispatchQueue.main.async { [weak self] in
//            self?.playbackStatePublisher.send(.completed(chapterAtEnd))
//        }
//    }
//
////    func audioEnginePlaybackStarted(_ notificationHandler: FindawayPlaybackNotificationHandler, for findawayChapter: FAEChapterDescription) {
////        func handlePlaybackStartedFor(findawayChapter: FAEChapterDescription, shouldPause: Bool) {
////            if !self.cursorChapterIsAt(part: findawayChapter.partNumber, number: findawayChapter.chapterNumber, audiobookID: findawayChapter.audiobookID) {
////                let cursorPredicate = { (spineElement: SpineElement) -> Bool in
////                    return spineElement.chapter.number == findawayChapter.chapterNumber && spineElement.chapter.part == findawayChapter.partNumber
////                }
////                if let newCursor = self.cursor.cursor(at: cursorPredicate) {
////                    self.cursor = newCursor
////                }
////            }
////
////            guard !shouldPause else {
////                self.performPause()
////                return
////            }
////
////            if let chapter = self.currentChapterLocation {
////                DispatchQueue.main.async { [weak self] () -> Void in
////                    self?.notifyDelegatesOfPlaybackFor(chapter: chapter)
////                }
////            }
////        }
////
////        self.queue.async {
////            handlePlaybackStartedFor(findawayChapter: findawayChapter, shouldPause: self.shouldPauseWhenPlaybackResumes)
////            self.shouldPauseWhenPlaybackResumes = false
////        }
////    }
//    func audioEnginePlaybackStarted(_ notificationHandler: FindawayPlaybackNotificationHandler, for findawayChapter: FAEChapterDescription) {
//        self.queue.async { [weak self] in
//            guard let self = self else { return }
//            
//            if let currentChapter = self.chapter(for: findawayChapter) {
//                if self.shouldPauseWhenPlaybackResumes {
//                    self.performPause()
//                } else {
//                    DispatchQueue.main.async {
//                        self.playbackStatePublisher.send(.started(currentChapter.position))
//                    }
//                }
//            }
//            // Reset the pause flag regardless of whether the chapter was found or not
//            self.shouldPauseWhenPlaybackResumes = false
//        }
//    }
//
//    func audioEnginePlaybackPaused(_ notificationHandler: FindawayPlaybackNotificationHandler, for findawayChapter: FAEChapterDescription) {
//        if let currentTrackPosition = currentTrackPosition ?? chapter(for: findawayChapter)?.position {
//            DispatchQueue.main.async { [weak self] () -> Void in
//                self?.playbackStatePublisher.send(.stopped(currentTrackPosition))
//            }
//            
//            self.queue.sync {
//                switch self.queuedPlayerState {
//                case .none:
//                    self.queuedPlayerState = .paused(currentTrackPosition)
//                default:
//                    break
//                }
//            }
//        }
//    }
//
//    func audioEnginePlaybackFailed(_ notificationHandler: FindawayPlaybackNotificationHandler, withError error: NSError?, for chapter: FAEChapterDescription) {
//        guard let locationOfError = self.chapter(for: chapter)?.position else { return }
//        DispatchQueue.main.async { [weak self] in
//            self?.playbackStatePublisher.send(.failed(locationOfError, error))
//        }
//    }
//    
//    func audioEngineAudiobookCompleted(_ notificationHandler: FindawayPlaybackNotificationHandler, for audiobookID: String) {
//        if self.audiobookID == audiobookID {
//            ATLog(.debug, "Findaway Audiobook did complete: \(audiobookID)")
//        } else {
//            ATLog(.error, "Invalid State: Completed Audiobook \(audiobookID) does not belong to this Player \(self.audiobookID).")
//        }
//    }
//}
//
//extension AudiobookTableOfContents {
//    var sessionKey: String? { manifest.metadata?.drmInformation?.sessionKey }
//    var licenseID: String? { manifest.metadata?.drmInformation?.licenseID }
//}
