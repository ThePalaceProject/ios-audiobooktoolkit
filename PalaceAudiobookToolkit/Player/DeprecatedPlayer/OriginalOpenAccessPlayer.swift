//import AVFoundation
//
//class OriginalOpenAccessPlayer: NSObject, OriginalPlayer {
//    var queuesEvents: Bool = false
//    var taskCompletion: Completion? = nil
//
//    var errorDomain: String {
//        return OpenAccessPlayerErrorDomain
//    }
//    
//    var taskCompleteNotification: Notification.Name {
//        return OpenAccessTaskCompleteNotification
//    }
//    
//    var interruptionNotification: Notification.Name {
//        return AudioInterruptionNotification
//    }
//    
//    var routeChangeNotification: Notification.Name {
//        return AudioRouteChangeNotification
//    }
//    
//    var isPlaying: Bool {
//        return self.avQueuePlayerIsPlaying
//    }
//    
//    var isDrmOk: Bool {
//        didSet {
//            if !isDrmOk {
//                pause()
//                notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil))
//                unload()
//            }
//        }
//    }
//    
//    @objc func setupNotifications() {
//        // Get the default notification center instance.
//        let nc = NotificationCenter.default
//        nc.addObserver(self,
//                       selector: #selector(handleInterruption),
//                       name: interruptionNotification,
//                       object: nil)
//        
//        nc.addObserver(self,
//                       selector: #selector(handleRouteChange),
//                       name: routeChangeNotification,
//                       object: nil)
//    }
//
//    private var avQueuePlayerIsPlaying: Bool = false {
//        didSet {
//            if let location = self.currentChapterLocation {
//                if oldValue == false && avQueuePlayerIsPlaying == true {
//                    self.notifyDelegatesOfPlaybackFor(chapter: location)
//                } else if oldValue == true && avQueuePlayerIsPlaying == false {
//                    self.notifyDelegatesOfPauseFor(chapter: location)
//                }
//            }
//        }
//    }
//
//    /// AVPlayer returns 0 for being "paused", but the protocol expects the
//    /// "user-chosen rate" upon playing.
//    var playbackRate: Original_PlaybackRate {
//        set {
//            if self.avQueuePlayer.rate != 0.0 {
//                let rate = Original_PlaybackRate.convert(rate: newValue)
//                self.avQueuePlayer.rate = rate
//            }
//
//            savePlaybackRate(rate: newValue)
//        }
//
//        get {
//            fetchPlaybackRate() ?? .normalTime
//        }
//    }
//
//    var currentChapterLocation: ChapterLocation? {
//        let avPlayerOffset = self.avQueuePlayer.currentTime().seconds
//        let playerItemStatus = self.avQueuePlayer.currentItem?.status
//        let offset: TimeInterval
//        if !avPlayerOffset.isNaN && playerItemStatus == .readyToPlay {
//            offset = avPlayerOffset
//        } else {
//            offset = 0
//        }
//
//        return ChapterLocation(
//            number: self.chapterAtCurrentCursor.number,
//            part: self.chapterAtCurrentCursor.part,
//            duration: self.chapterAtCurrentCursor.duration,
//            startOffset: self.chapterAtCurrentCursor.chapterOffset ?? 0,
//            playheadOffset: offset,
//            title: self.chapterAtCurrentCursor.title,
//            audiobookID: self.audiobookID
//        )
//    }
//
//    var isLoaded = true
//
//    func play()
//    {
//        // Check DRM
//        if !isDrmOk {
//            ATLog(.warn, "DRM is flagged as failed.")
//            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.drmExpired.rawValue, userInfo: nil)
//            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
//            return
//        }
//
//        switch self.playerIsReady {
//        case .readyToPlay:
//            self.cursorQueuedToPlay = self.cursor
//
//            self.avQueuePlayer.play()
//            let rate = Original_PlaybackRate.convert(rate: self.playbackRate)
//            if rate != self.avQueuePlayer.rate {
//                self.avQueuePlayer.rate = rate
//            }
//        case .unknown:
//            self.cursorQueuedToPlay = self.cursor
//            ATLog(.error, "Player not yet ready. QueuedToPlay = true.")
//            if self.avQueuePlayer.currentItem == nil {
//                if let fileStatus = assetFileStatus(self.cursor.currentElement.downloadTask) {
//                    switch fileStatus {
//                    case .saved(let savedURLs):
//                        let item = createPlayerItem(files: savedURLs) ?? AVPlayerItem(url: savedURLs[0])
//                        
//                        if self.avQueuePlayer.canInsert(item, after: nil) {
//                            self.avQueuePlayer.insert(item, after: nil)
//                        }
//                    case .missing(_):
//                        self.rebuildOnFinishedDownload(task: self.cursor.currentElement.downloadTask)
//                    default:
//                        break
//                    }
//                }
//            }
//        case .failed:
//            ATLog(.error, "Ready status is \"failed\".")
//            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
//            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
//            break
//        }
//    }
//
//    private func createPlayerItem(files: [URL]) -> AVPlayerItem? {
//        guard files.count > 1 else { return AVPlayerItem(url: files[0]) }
//
//        let composition = AVMutableComposition()
//        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
//
//        do {
//            for (index, file) in files.enumerated() {
//                let asset = AVAsset(url: file)
//                if index == files.count - 1 {
//                    try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: asset.tracks(withMediaType: .audio)[0], at: compositionAudioTrack?.asset?.duration ?? .zero)
//                } else {
//                    try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: asset.tracks(withMediaType: .audio)[0], at: compositionAudioTrack?.asset?.duration ?? .zero)
//                }
//            }
//        } catch {
//            ATLog(.error, "Player not yet ready. QueuedToPlay = true.")
//            return nil
//        }
//
//        return AVPlayerItem(asset: composition)
//    }
//
//    func pause()
//    {
//        if self.isPlaying {
//            self.avQueuePlayer.pause()
//        } else if self.cursorQueuedToPlay != nil {
//            self.cursorQueuedToPlay = nil
//            NotificationCenter.default.removeObserver(self, name: taskCompleteNotification, object: nil)
//            notifyDelegatesOfPauseFor(chapter: self.chapterAtCurrentCursor)
//        }
//    }
//
//    func unload()
//    {
//        self.isLoaded = false
//        self.avQueuePlayer.removeAllItems()
//        self.notifyDelegatesOfUnloadRequest()
//    }
//    
//    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((ChapterLocation?)->())? = nil) {
//        queuedSeekOffset = nil
//        cursorQueuedToPlay = nil
//        
//        guard let currentLocation = currentChapterLocation else {
//            ATLog(.error, "Current chapter location is not available.")
//            completion?(nil)
//            return
//        }
//        
//        if timeInterval >= 0 {
//            skipForward(timeInterval, from: currentLocation, completion: completion)
//        } else {
//            skipBackward(timeInterval, from: currentLocation, completion: completion)
//        }
//    }
//
//    private func skipForward(_ timeInterval: TimeInterval, from currentLocation: ChapterLocation, completion: ((ChapterLocation) -> ())?) {
//        var timeIntervalRemaining = timeInterval
//        let remainingTimeInCurrentChapter = currentLocation.duration - currentLocation.actualOffset
//        
//        // Case 1: Skip within the current chapter
//        if timeIntervalRemaining < remainingTimeInCurrentChapter {
//            let newOffset = currentLocation.playheadOffset + timeIntervalRemaining
//            guard let newLocation = currentLocation.update(playheadOffset: newOffset) else { return }
//            updatePlayhead(for: newLocation, withOffset: newOffset, completion: completion)
//        } else {
//            // Case 2 & 3: Skip requires moving to next chapter(s)
//            timeIntervalRemaining -= remainingTimeInCurrentChapter
//            
//            var nextChapterCursor = cursor.next()
//            while let nextChapter = nextChapterCursor?.currentElement.chapter, timeIntervalRemaining > 0 {
//                if timeIntervalRemaining < nextChapter.duration {
//                    // Skip is within the next chapter
//                    let newOffset = max(timeIntervalRemaining, nextChapter.chapterOffset ?? 0)
//                    guard let newLocation = nextChapter.update(playheadOffset: newOffset) else { return }
//                    playAtLocation(newLocation)
//                    completion?(newLocation)
//                    return
//                } else {
//                    // Skip exceeds the duration of the next chapter, move to the following chapter
//                    timeIntervalRemaining -= nextChapter.duration
//                    nextChapterCursor = nextChapterCursor?.next()
//                }
//            }
//            
//            // Case 4: End of the audiobook or no more chapters to skip through
//            if let lastChapter = nextChapterCursor?.currentElement.chapter {
//                // Attempt to set the playhead to the end of the last available chapter
//                guard let newLocation = lastChapter.update(playheadOffset: lastChapter.duration) else { return }
//                playAtLocation(newLocation)
//                completion?(newLocation)
//            } else {
//                // Handle the scenario where we cannot skip any further
//                ATLog(.error, "Reached the end of the audiobook or no more chapters available for skipping.")
//                let currentChapter = cursor.currentElement.chapter
//                guard let newLocation = currentChapter.update(playheadOffset: currentChapter.duration) else { return }
//                updatePlayhead(for: newLocation, withOffset: currentChapter.duration, completion: completion)
//            }
//        }
//    }
//
//    private func skipBackward(_ timeInterval: TimeInterval, from currentLocation: ChapterLocation, completion: ((ChapterLocation?) -> ())?) {
//        var timeIntervalRemaining = abs(timeInterval) // Ensure positive value for calculation
//        let actualOffsetInCurrentChapter = currentLocation.actualOffset // Assuming this is correctly calculated
//        
//        // Case 1: Skip within the current chapter
//        if timeIntervalRemaining <= actualOffsetInCurrentChapter {
//            // Calculate new offset ensuring it doesn't go below zero
//            let newOffset = max(currentLocation.playheadOffset - timeIntervalRemaining, 0)
//            guard let newLocation = currentLocation.update(playheadOffset: newOffset) else { return }
//            updatePlayhead(for: newLocation, withOffset: newOffset, completion: completion)
//        } else {
//            // Case 2 & 3: Skip requires moving to previous chapter(s)
//            timeIntervalRemaining -= actualOffsetInCurrentChapter
//            
//            var previousChapterCursor = cursor.prev()
//            while let previousChapter = previousChapterCursor?.currentElement.chapter {
//                let chapterDuration = previousChapter.duration
//                if timeIntervalRemaining < chapterDuration {
//                    // Calculate the offset from the end of the chapter
//                    let newOffset = chapterDuration - timeIntervalRemaining
//                    guard let newLocation = previousChapter.update(playheadOffset: newOffset) else { return }
//                    playAtLocation(newLocation)
//                    completion?(newLocation)
//                    return
//                }
//                timeIntervalRemaining -= chapterDuration
//                previousChapterCursor = previousChapterCursor?.prev()
//            }
//            
//            // Case 4: Reached the beginning of the audiobook or no more chapters to skip through
//            if let firstChapter = cursor.first()?.currentElement.chapter {
//                // Set the playhead to the beginning of the first chapter
//                guard let newLocation = firstChapter.update(playheadOffset: 0) else { return }
//                playAtLocation(newLocation)
//                completion?(newLocation)
//            } else {
//                // In case the cursor does not have a 'first' method, fallback to current location with offset 0
//                // This case might occur if the audiobook structure is unusual or if there's an issue with the cursor implementation
//                guard let newLocation = currentLocation.update(playheadOffset: 0) else { return }
//                playAtLocation(newLocation)
//                completion?(newLocation)
//            }
//        }
//    }
//
//    private func updatePlayhead(for location: ChapterLocation, withOffset offset: TimeInterval, completion: ((ChapterLocation)->())?) {
//        guard let newLocation = location.update(playheadOffset: offset) else {
//            ATLog(.error, "New chapter location could not be created.")
//            return
//        }
//        playAtLocation(newLocation)
//        completion?(newLocation)
//    }
//
//
//
//    /// New Location's playhead offset could be oustide the bounds of audio, so
//    /// move and get a reference to the actual new chapter location. Only update
//    /// the cursor if a new queue can successfully be built for the player.
//    ///
//    /// - Parameter newLocation: Chapter Location with possible playhead offset
//    ///   outside the bounds of audio for the current chapter
//    func playAtLocation(_ newLocation: ChapterLocation, completion: Completion? = nil) {
//        let newPlayhead = move(cursor: self.cursor, to: newLocation)
//
//        guard let newItemDownloadStatus = assetFileStatus(newPlayhead.cursor.currentElement.downloadTask) else {
//            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
//            notifyDelegatesOfPlaybackFailureFor(chapter: newPlayhead.location, error)
//            completion?(error)
//            return
//        }
//
//        switch newItemDownloadStatus {
//        case .saved(_):
//            // If we're in the same AVPlayerItem, apply seek directly with AVPlayer.
//            if newPlayhead.location.inSameChapter(other: self.chapterAtCurrentCursor) {
//                self.seekWithinCurrentItem(newOffset: newPlayhead.location.playheadOffset) {
//                    completion?(nil)
//                    return
//                }
//            }
//            // Otherwise, check for an AVPlayerItem at the new cursor, rebuild the player
//            // queue starting from there, and then begin playing at that location.
//            self.buildNewPlayerQueue(atCursor: newPlayhead.cursor) { (success) in
//                if success {
//                    self.cursor = newPlayhead.cursor
//                    self.seekWithinCurrentItem(newOffset: newPlayhead.location.playheadOffset, forceSync: true) {
//                        self.play()
//                        completion?(nil)
//                    }
//                } else {
//                    ATLog(.error, "Failed to create a new queue for the player. Keeping playback at the current player item.")
//                    let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
//                    self.notifyDelegatesOfPlaybackFailureFor(chapter: newLocation, error)
//                    completion?(error)
//                }
//            }
//        case .missing(_):
//            self.cursor = newPlayhead.cursor
//            self.queuedSeekOffset = newPlayhead.location.playheadOffset
//
//            // TODO: Could eventually handle streaming from here.
//            guard self.playerIsReady != .readyToPlay || self.playerIsReady != .failed else {
//                let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.downloadNotFinished.rawValue, userInfo: nil)
//                self.notifyDelegatesOfPlaybackFailureFor(chapter: newLocation, error)
//                completion?(error)
//                return
//            }
//
//            self.taskCompletion = completion
//            rebuildOnFinishedDownload(task: newPlayhead.cursor.currentElement.downloadTask)
//            return
//    
//        case .unknown:
//            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
//            self.notifyDelegatesOfPlaybackFailureFor(chapter: newLocation, error)
//            return
//        }
//    }
//
//    func movePlayheadToLocation(_ location: ChapterLocation, completion: Completion? = nil)
//    {
//        self.playAtLocation(location, completion: completion)
//    }
//
//    /// Moving within the current AVPlayerItem.
//    private func seekWithinCurrentItem(newOffset: TimeInterval, forceSync: Bool = false, completion: (() -> Void)? = nil) {
//        defer {
//            completion?()
//        }
//
//        guard let currentItem = avQueuePlayer.currentItem else {
//            ATLog(.error, "No current AVPlayerItem in AVQueuePlayer to seek.")
//            return
//        }
//        
//        if currentItem.status != .readyToPlay && !forceSync {
//            ATLog(.debug, "AVPlayerItem not ready to play. Queuing seek offset: \(newOffset)")
//            queuedSeekOffset = newOffset
//            return
//        }
//        
//        let effectiveOffset = queuedSeekOffset ?? newOffset
//        
//        currentItem.seek(to: CMTime(seconds: effectiveOffset, preferredTimescale: CMTimeScale(NSEC_PER_SEC))) { [weak self] finished in
//            guard let self = self else { return }
//            
//            if finished {
//                queuedSeekOffset = nil
//                self.cursorQueuedToPlay = nil
//                ATLog(.debug, "Seek operation to offset \(effectiveOffset) finished.")
//                let updatedChapter = self.chapterAtCurrentCursor.update(playheadOffset: effectiveOffset)
//                self.notifyDelegatesOfPlaybackFor(chapter: updatedChapter ?? self.chapterAtCurrentCursor)
//            } else {
//                queuedSeekOffset = newOffset
//                self.cursorQueuedToPlay = self.cursor
//
//                ATLog(.error, "Seek operation failed on AVPlayerItem")
//            }
//        }
//    }
//
//    func registerDelegate(_ delegate: Original_PlayerDelegate)
//    {
//        self.delegates.add(delegate)
//    }
//
//    func removeDelegate(_ delegate: Original_PlayerDelegate)
//    {
//        self.delegates.remove(delegate)
//    }
//
//    private var chapterAtCurrentCursor: ChapterLocation
//    {
//        return self.cursor.currentElement.chapter
//    }
//
//    /// The overallDownloadProgress readiness of an AVPlayer and the currently queued AVPlayerItem's readiness values.
//    /// You cannot play audio without both being "ready."
//    fileprivate func overallPlayerReadiness(player: AVPlayer.Status, item: AVPlayerItem.Status?) -> AVPlayerItem.Status
//    {
//        let avPlayerStatus = AVPlayerItem.Status(rawValue: self.avQueuePlayer.status.rawValue) ?? .unknown
//        let playerItemStatus = self.avQueuePlayer.currentItem?.status ?? .unknown
//        if avPlayerStatus == playerItemStatus {
//            ATLog(.debug, "overallPlayerReadiness::avPlayerStatus \(avPlayerStatus.description)")
//            return avPlayerStatus
//        } else {
//            ATLog(.debug, "overallPlayerReadiness::playerItemStatus \(playerItemStatus.description)")
//            return playerItemStatus
//        }
//    }
//
//    /// This should only be set by the AVPlayer via KVO.
//    private var playerIsReady: AVPlayerItem.Status = .unknown {
//        didSet {
//            switch playerIsReady {
//            case .readyToPlay:
//                // Perform any queued operations like play(), and then seek().
//                if let cursor = self.cursorQueuedToPlay {
//                    self.cursorQueuedToPlay = nil
//                    self.buildNewPlayerQueue(atCursor: cursor) { success in
//                        if success {
//                            self.seekWithinCurrentItem(newOffset: (self.queuedSeekOffset ?? 0) > 0 ? self.queuedSeekOffset ?? self.chapterAtCurrentCursor.playheadOffset : self.chapterAtCurrentCursor.playheadOffset, forceSync: true) {
//                                self.play()
//                            }
//                        } else {
//                            ATLog(.error, "User attempted to play when the player wasn't ready.")
//                            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.playerNotReady.rawValue, userInfo: nil)
//                            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
//                        }
//                    }
//                }
//            case .failed:
//                fallthrough
//            case .unknown:
//                break
//            }
//        }
//    }
//
//    private let avQueuePlayer: AVQueuePlayer
//    private let audiobookID: String
//    private var cursor: Cursor<SpineElement>
//    private var queuedSeekOffset: TimeInterval?
//    private var cursorQueuedToPlay: Cursor<SpineElement>?
//    private var playerContext = 0
//
//    var delegates: NSHashTable<Original_PlayerDelegate> = NSHashTable(options: [NSPointerFunctions.Options.weakMemory])
//
//    required init(cursor: Cursor<SpineElement>, audiobookID: String, drmOk: Bool) {
//
//        self.cursor = cursor
//        self.audiobookID = audiobookID
//        self.isDrmOk = drmOk // Skips didSet observer
//        self.avQueuePlayer = AVQueuePlayer()
//        super.init()
//
//        self.setupNotifications()
//        self.buildNewPlayerQueue(atCursor: self.cursor) { _ in }
//
//        if #available(iOS 10.0, *) {
//            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
//        } else {
//            // https://forums.swift.org/t/using-methods-marked-unavailable-in-swift-4-2/14949
//            AVAudioSession.sharedInstance().perform(NSSelectorFromString("setCategory:error:"),
//                                                    with: AVAudioSession.Category.playback)
//        }
//        try? AVAudioSession.sharedInstance().setActive(true, options: [])
//
//        self.addPlayerObservers()
//    }
//
//    deinit {
//        self.removePlayerObservers()
//        try? AVAudioSession.sharedInstance().setActive(false, options: [])
//    }
//
//    private func buildNewPlayerQueue(atCursor cursor: Cursor<SpineElement>, completion: (Bool)->())
//    {
//        let items = self.buildPlayerItems(fromCursor: cursor)
//        if items.isEmpty {
//            completion(false)
//        } else {
//            for item in self.avQueuePlayer.items() {
//                NotificationCenter.default.removeObserver(self,
//                                                          name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
//                                                          object: item)
//            }
//            self.avQueuePlayer.removeAllItems()
//            for item in items {
//                if self.avQueuePlayer.canInsert(item, after: nil) {
//                    NotificationCenter.default.addObserver(self,
//                                                           selector:#selector(advanceToNextPlayerItem),
//                                                           name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
//                                                           object: item)
//                    self.avQueuePlayer.insert(item, after: nil)
//                } else {
//                    var errorMessage = "Cannot insert item: \(item). Discrepancy between AVPlayerItems and what could be inserted. "
//                    if self.avQueuePlayer.items().count >= 1 {
//                        errorMessage = errorMessage + "Returning as Success with a partially complete queue."
//                        completion(true)
//                    } else {
//                        errorMessage = errorMessage + "No items were queued. Returning as Failure."
//                        completion(false)
//                    }
//                    ATLog(.error, errorMessage)
//                    return
//                }
//            }
//            completion(true)
//        }
//    }
//
//    /// Queue all valid AVPlayerItems from the cursor up to any spine element that's missing it.
//    private func buildPlayerItems(fromCursor cursor: Cursor<SpineElement>?) -> [AVPlayerItem]
//    {
//        var items = [AVPlayerItem]()
//        var cursor = cursor
//
//        while (cursor != nil) {
//            guard let fileStatus = assetFileStatus(cursor!.currentElement.downloadTask) else {
//                cursor = nil
//                continue
//            }
//            switch fileStatus {
//            case .saved(let assetURLs):
//                let playerItem = createPlayerItem(files: assetURLs) ?? AVPlayerItem(url: assetURLs[0])
//                playerItem.audioTimePitchAlgorithm = .timeDomain
//                items.append(playerItem)
//            case .missing(_):
//                fallthrough
//            case .unknown:
//                cursor = nil
//                continue
//            }
//            cursor = cursor?.next()
//        }
//        return items
//    }
//
//    /// Update the cursor if the next item in the queue is about to be put on.
//    /// Not needed for explicit seek operations. Check the player for any more
//    /// AVPlayerItems so that we can potentially rebuild the queue if more
//    /// downloads have completed since the queue was last built.
//    @objc func currentPlayerItemEnded(item: AVPlayerItem? = nil)
//    {
//        DispatchQueue.main.async {
//            let currentCursor = self.cursor
//            if let nextCursor = self.cursor.next() {
//                self.cursor = nextCursor
//                
//                if self.avQueuePlayer.items().count <= 1 {
//                    self.pause()
//                    ATLog(.debug, "Attempting to recover the missing AVPlayerItem.")
//                    self.attemptToRecoverMissingPlayerItem(cursor: currentCursor)
//                }
//            } else {
//                ATLog(.debug, "End of book reached.")
//                self.pause()
//            }
//            
//            self.notifyDelegatesOfPlaybackEndFor(chapter: currentCursor.currentElement.chapter)
//        }
//    }
//    
//    @objc func advanceToNextPlayerItem() {
//        let currentCursor = self.cursor
//        guard let nextCursor = self.cursor.next() else {
//            ATLog(.debug, "End of book reached.")
//            self.pause()
//            self.notifyDelegatesOfPlaybackEndFor(chapter: currentCursor.currentElement.chapter)
//            return
//        }
//
//        self.cursor = nextCursor
//        self.avQueuePlayer.advanceToNextItem()
//        seekWithinCurrentItem(newOffset: Double(self.cursor.currentElement.chapter.chapterOffset?.seconds ?? 0))
//        self.notifyDelegatesOfPlaybackEndFor(chapter: currentCursor.currentElement.chapter)
//    }
//
//    /// Try and recover from a Cursor missing its player asset.
//    func attemptToRecoverMissingPlayerItem(cursor: Cursor<SpineElement>)
//    {
//        if let fileStatus = assetFileStatus(self.cursor.currentElement.downloadTask) {
//            switch fileStatus {
//            case .saved(_):
//                self.rebuildQueueAndSeekOrPlay(cursor: cursor)
//            case .missing(_):
//                self.rebuildOnFinishedDownload(task: self.cursor.currentElement.downloadTask)
//            case .unknown:
//                let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.playerNotReady.rawValue, userInfo: nil)
//                self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
//            }
//        } else {
//            let error = NSError(domain: errorDomain, code: OpenAccessPlayerError.unknown.rawValue, userInfo: nil)
//            self.notifyDelegatesOfPlaybackFailureFor(chapter: self.chapterAtCurrentCursor, error)
//        }
//    }
//
//    // Will seek to new offset and pause, if provided.
//    func rebuildQueueAndSeekOrPlay(cursor: Cursor<SpineElement>, newOffset: TimeInterval? = nil)
//    {
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
//
//    fileprivate func rebuildOnFinishedDownload(task: DownloadTask)
//    {
//        ATLog(.debug, "Added observer for missing download task.")
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.downloadTaskFinished),
//                                               name: taskCompleteNotification,
//                                               object: task)
//    }
//
//    @objc func downloadTaskFinished()
//    {
//        self.rebuildQueueAndSeekOrPlay(cursor: self.cursor, newOffset: self.queuedSeekOffset)
//        self.taskCompletion?(nil)
//        self.taskCompletion = nil
//        NotificationCenter.default.removeObserver(self, name: taskCompleteNotification, object: nil)
//    }
//    
//    func assetFileStatus(_ task: DownloadTask) -> AssetResult? {
//        guard let task = task as? OpenAccessDownloadTask else {
//            return nil
//        }
//        return task.assetFileStatus()
//    }
//}
//
///// Key-Value Observing on AVPlayer properties and items
//extension OriginalOpenAccessPlayer{
//    override func observeValue(forKeyPath keyPath: String?,
//                               of object: Any?,
//                               change: [NSKeyValueChangeKey : Any]?,
//                               context: UnsafeMutableRawPointer?)
//    {
//        guard context == &playerContext else {
//            super.observeValue(forKeyPath: keyPath,
//                               of: object,
//                               change: change,
//                               context: context)
//            return
//        }
//
//        func updatePlayback(player: AVPlayer, item: AVPlayerItem?) {
//            ATLog(.debug, "updatePlayback, playerStatus: \(player.status.description) item: \(item?.status.description ?? "")")
//            DispatchQueue.main.async {
//                self.playerIsReady = self.overallPlayerReadiness(player: player.status, item: item?.status)
//            }
//        }
//
//        func avPlayer(isPlaying: Bool) {
//            DispatchQueue.main.async {
//                if self.avQueuePlayerIsPlaying != isPlaying {
//                    self.avQueuePlayerIsPlaying = isPlaying
//                }
//            }
//        }
//
//        if keyPath == #keyPath(AVQueuePlayer.status) {
//            let status: AVQueuePlayer.Status
//            if let statusNumber = change?[.newKey] as? NSNumber {
//                status = AVQueuePlayer.Status(rawValue: statusNumber.intValue)!
//            } else {
//                status = .unknown
//            }
//
//            switch status {
//            case .readyToPlay:
//                ATLog(.debug, "AVQueuePlayer status: ready to play.")
//            case .failed:
//                let error = (object as? AVQueuePlayer)?.error.debugDescription ?? "error: nil"
//                ATLog(.error, "AVQueuePlayer status: failed. Error:\n\(error)")
//            case .unknown:
//                ATLog(.debug, "AVQueuePlayer status: unknown.")
//            }
//
//            if let player = object as? AVPlayer {
//                updatePlayback(player: player, item: player.currentItem)
//            }
//        }
//        else if keyPath == #keyPath(AVQueuePlayer.rate) {
//            if let newRate = change?[.newKey] as? Float,
//                let oldRate = change?[.oldKey] as? Float,
//                let player = (object as? AVQueuePlayer) {
//                if (player.error == nil) {
//                    if (oldRate == 0.0) && (newRate != 0.0) {
//                        avPlayer(isPlaying: true)
//                    } else if (oldRate != 0.0) && (newRate == 0.0) {
//                        avPlayer(isPlaying: false)
//                    }
//                    return
//                } else {
//                    ATLog(.error, "AVPlayer error: \n\(player.error.debugDescription)")
//                }
//            }
//            avPlayer(isPlaying: false)
//            ATLog(.error, "KVO Observing did not deserialize correctly.")
//        }
//        else if keyPath == #keyPath(AVQueuePlayer.currentItem.status) {
//            let oldStatus: AVPlayerItem.Status
//            let newStatus: AVPlayerItem.Status
//            if let oldStatusNumber = change?[.oldKey] as? NSNumber,
//            let newStatusNumber = change?[.newKey] as? NSNumber {
//                oldStatus = AVPlayerItem.Status(rawValue: oldStatusNumber.intValue)!
//                newStatus = AVPlayerItem.Status(rawValue: newStatusNumber.intValue)!
//            } else {
//                oldStatus = .unknown
//                newStatus = .unknown
//            }
//
//            if let player = object as? AVPlayer,
//                oldStatus != newStatus {
//                updatePlayback(player: player, item: player.currentItem)
//            }
//        }
//        else if keyPath == #keyPath(AVQueuePlayer.reasonForWaitingToPlay) {
//            if let reason = change?[.newKey] as? AVQueuePlayer.WaitingReason {
//                ATLog(.debug, "Reason for waiting to play: \(reason)")
//            }
//        }
//    }
//
//    fileprivate func notifyDelegatesOfPlaybackFor(chapter: ChapterLocation) {
//        self.delegates.allObjects.forEach { (delegate) in
//            delegate.player(self, didBeginPlaybackOf: chapter)
//        }
//    }
//
//    fileprivate func notifyDelegatesOfPauseFor(chapter: ChapterLocation) {
//        self.delegates.allObjects.forEach { (delegate) in
//            delegate.player(self, didStopPlaybackOf: chapter)
//        }
//    }
//
//    fileprivate func notifyDelegatesOfPlaybackFailureFor(chapter: ChapterLocation, _ error: NSError?) {
//        self.delegates.allObjects.forEach { (delegate) in
//            delegate.player(self, didFailPlaybackOf: chapter, withError: error)
//        }
//    }
//
//    fileprivate func notifyDelegatesOfPlaybackEndFor(chapter: ChapterLocation) {
//        self.delegates.allObjects.forEach { (delegate) in
//            delegate.player(self, didComplete: chapter)
//        }
//    }
//
//    fileprivate func notifyDelegatesOfUnloadRequest() {
//        self.delegates.allObjects.forEach { (delegate) in
//            delegate.playerDidUnload(self)
//        }
//    }
//
//    fileprivate func addPlayerObservers() {
//        self.avQueuePlayer.addObserver(self,
//                                       forKeyPath: #keyPath(AVQueuePlayer.status),
//                                       options: [.old, .new],
//                                       context: &playerContext)
//
//        self.avQueuePlayer.addObserver(self,
//                                       forKeyPath: #keyPath(AVQueuePlayer.rate),
//                                       options: [.old, .new],
//                                       context: &playerContext)
//
//        self.avQueuePlayer.addObserver(self,
//                                       forKeyPath: #keyPath(AVQueuePlayer.currentItem.status),
//                                       options: [.old, .new],
//                                       context: &playerContext)
//        
//        self.avQueuePlayer.addObserver(self,
//                                       forKeyPath: #keyPath(AVQueuePlayer.reasonForWaitingToPlay),
//                                       options: [.old, .new],
//                                       context: &playerContext)
//    }
//
//    fileprivate func removePlayerObservers() {
//        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.status))
//        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.rate))
//        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.currentItem.status))
//        self.avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVQueuePlayer.reasonForWaitingToPlay))
//        NotificationCenter.default.removeObserver(self, name: interruptionNotification, object: nil)
//    }
//
//    @objc func handleInterruption(notification: Notification) {
//        guard let userInfo = notification.userInfo,
//                let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
//                let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
//                    return
//            }
//
//            switch type {
//            case .began:
//                ATLog(.warn, "System audio interruption began.")
//            case .ended:
//                ATLog(.warn, "System audio interruption ended.")
//                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
//                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
//                if options.contains(.shouldResume) {
//                    play()
//                } else {
//                    play()
//                }
//            default: ()
//            }
//    }
//    
//    @objc func handleRouteChange(notification: Notification) {
//        guard let userInfo = notification.userInfo,
//              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
//              let reason = AVAudioSession.RouteChangeReason(rawValue:reasonValue) else {
//            return
//        }
//        
//        switch reason {
//        case .newDeviceAvailable:
//            let session = AVAudioSession.sharedInstance()
//            for output in session.currentRoute.outputs {
//                switch output.portType {
//                case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
//                    play()
//                default: ()
//                }
//            }
//        case .oldDeviceUnavailable:
//            if let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
//                for output in previousRoute.outputs {
//                    switch output.portType {
//                    case AVAudioSession.Port.headphones, AVAudioSession.Port.bluetoothA2DP:
//                        pause()
//                    default: ()
//                    }
//                }
//            }
//        default: ()
//        }
//    }
//}
