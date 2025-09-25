//
//  LCPStreamingPlayer.swift
//  PalaceAudiobookToolkit
//
//  LCP streaming player using custom URLs and resource loader.
//

import Foundation
import AVFoundation
import ReadiumShared
import ObjectiveC

/// LCP streaming player that uses custom lcp:// URLs with resource loader
class LCPStreamingPlayer: OpenAccessPlayer, StreamingCapablePlayer {
    
    // MARK: - StreamingCapablePlayer conformance
    public func setStreamingProvider(_ provider: StreamingResourceProvider) {
        streamingProvider = provider
        sharedResourceLoader = LCPResourceLoaderDelegate(provider: provider)
    }
    
    private weak var streamingProvider: StreamingResourceProvider?
    private let resourceLoaderQueue = DispatchQueue(label: "com.palace.lcp-streaming-loader", qos: .userInitiated)
    private static var resourceLoaderAssocKey: UInt8 = 0
    private let decryptionDelegate: DRMDecryptor?
    
    public var decryptor: DRMDecryptor? {
        return decryptionDelegate
    }
    private var forceStreamingTrackKeys = Set<String>()
    private let compositionQueue = DispatchQueue(label: "com.palace.lcp.local-composition", qos: .userInitiated)
    
    private var sharedResourceLoader: LCPResourceLoaderDelegate?
    private var isObservingTimeControlStatus = false
    private var suppressAudibleUntilPlaying = false
    private var lastStartedItemKey: String?
    
    override var currentOffset: Double {
        guard let currentTrackPosition, let currentChapter else {
            return 0
        }
        
        let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
        return offset
    }
    
    init(tableOfContents: AudiobookTableOfContents, drmDecryptor: DRMDecryptor? = nil) {
        self.decryptionDelegate = drmDecryptor
        super.init(tableOfContents: tableOfContents)
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        fatalError("init(tableOfContents:) has not been implemented")
    }
    


    override func configurePlayer() {
        setupAudioSession()
        addPlayerObservers()
        
        avQueuePlayer.actionAtItemEnd = .none
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        avQueuePlayer.isMuted = false
        isLoaded = false
    }

    override func addPlayerObservers() {
        super.addPlayerObservers()
        avQueuePlayer.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
        isObservingTimeControlStatus = true
    }

    override func removePlayerObservers() {
        if isObservingTimeControlStatus {
            avQueuePlayer.removeObserver(self, forKeyPath: "timeControlStatus")
            isObservingTimeControlStatus = false
        }
        super.removePlayerObservers()
    }

    override func buildPlayerQueue() {
        resetPlayerQueue()
        isLoaded = false
    }
    
    /// Build player items preferring local decrypted files, falling back to streaming
    public override func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
        var items = [AVPlayerItem]()
        
        for (index, track) in tracks.enumerated() {
            if let lcpTrack = track as? LCPTrack,
               !forceStreamingTrackKeys.contains(track.key),
               let task = lcpTrack.downloadTask as? LCPDownloadTask,
               case .saved(let urls) = task.assetFileStatus(), !urls.isEmpty {
                let localItem: AVPlayerItem
                if urls.count == 1 {
                    let asset = AVURLAsset(url: urls[0])
                    localItem = AVPlayerItem(asset: asset)
                } else {

                    if let compositionItem = createConcatenatedItem(from: urls) {
                        localItem = compositionItem
                    } else {
                        let item = createStreamingPlayerItem(for: track, index: index)
                        items.append(item)
                        addEndObserver(for: item)
                        continue
                    }
                }
                localItem.audioTimePitchAlgorithm = .timeDomain
                localItem.trackIdentifier = track.key
                items.append(localItem)
                safeAddObserver(to: localItem)
            } else {
                let item = createStreamingPlayerItem(for: track, index: index)
                items.append(item)
                addEndObserver(for: item)
                ATLog(.debug, "🎵 Created STREAMING item for track \(index): fake://lcp-streaming/track/\(index)")
            }
        }

        return items
    }

    // MARK: - Navigation aligned with LCPPlayer

    public override func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {

        avQueuePlayer.pause()
        (sharedResourceLoader as? LCPResourceLoaderDelegate)?.cancelAllRequests()
        isLoaded = false
        suppressAudibleUntilPlaying = true
        avQueuePlayer.isMuted = true
        lastStartedItemKey = nil
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            if let self = self, !self.isLoaded {
                ATLog(.warn, "🎵 [LCPStreamingPlayer] Publication loading taking longer than expected, attempting fallback")
                if self.streamingProvider?.getPublication() != nil || !self.avQueuePlayer.items().isEmpty {
                    ATLog(.info, "🎵 [LCPStreamingPlayer] Fallback: Publication or items available, proceeding")
                    self.isLoaded = true
                    self.suppressAudibleUntilPlaying = false
                    self.avQueuePlayer.isMuted = false
                } else {
                    ATLog(.error, "🎵 [LCPStreamingPlayer] Critical timeout: No publication or items available")
                }
            }
        }
        var needsRebuild = avQueuePlayer.items().isEmpty

        if !needsRebuild {
            if let targetIndex = avQueuePlayer.items().firstIndex(where: { $0.trackIdentifier == position.track.key }) {
                let item = avQueuePlayer.items()[targetIndex]
                let isCurrentlyLocal: Bool = {
                    if let urlAsset = item.asset as? AVURLAsset { return urlAsset.url.isFileURL }
                    return !(item.asset is AVURLAsset)
                }()
                if let lcpTrack = position.track as? LCPTrack {
                    let shouldBeLocal = lcpTrack.hasLocalFiles() && !forceStreamingTrackKeys.contains(lcpTrack.key)
                    if shouldBeLocal != isCurrentlyLocal {
                        needsRebuild = true
                    }
                }
            } else {
                needsRebuild = true
            }
        }

        if !needsRebuild {
            var queueItems = avQueuePlayer.items()
            if let targetIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
                let currentIndex = queueItems.firstIndex(where: { $0 == avQueuePlayer.currentItem }) ?? 0
                if targetIndex > currentIndex {
                    for _ in currentIndex..<targetIndex { avQueuePlayer.advanceToNextItem() }
                }
                let safeTs = safeTimestamp(for: position)
                let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] success in
                    guard let self = self else { return }
                    
                    if !success {
                        ATLog(.error, "🎵 [LCPStreamingPlayer] Seek failed, but continuing with playback")
                    }
                    
                    // Ensure session is active before resuming
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setActive(true)
                    } catch {
                        ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session: \(error)")
                    }
                    
                    self.avQueuePlayer.play()
                    self.restorePlaybackRate()
                    
                    // Set isLoaded immediately for seek-within-queue scenarios
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        if let self = self, !self.isLoaded {
                            self.isLoaded = true
                            self.suppressAudibleUntilPlaying = false 
                            self.avQueuePlayer.isMuted = false
                        }
                    }
                    
                    completion?(nil)
                }
                return
            }
        }

        let allTracks = tableOfContents.allTracks
        avQueuePlayer.removeAllItems()

        // Find target track index for windowing
        let targetTrackIndex = allTracks.firstIndex { $0.key == position.track.key } ?? 0

        // Add the target item FIRST so currentItem immediately reflects the intended chapter
        if targetTrackIndex < allTracks.count {
            let targetTrack = allTracks[targetTrackIndex]
            let targetItem = buildPlayerItem(for: targetTrack, index: targetTrackIndex)
            avQueuePlayer.insert(targetItem, after: nil)
            addEndObserver(for: targetItem)
        }
        // Then add a window of neighboring items lazily
        let windowSize = 5
        let startIndex = max(0, targetTrackIndex - 1)
        let endIndex = min(allTracks.count - 1, targetTrackIndex + windowSize)
        for i in startIndex...endIndex where i != targetTrackIndex {
            let track = allTracks[i]
            let item = buildPlayerItem(for: track, index: i)
            avQueuePlayer.insert(item, after: nil)
            addEndObserver(for: item)
        }

        var queueItems = avQueuePlayer.items()
        if let targetQueueIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
            for _ in 0..<targetQueueIndex { avQueuePlayer.advanceToNextItem() }
            let safeTs = safeTimestamp(for: position)
            let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] success in
                guard let self = self else { return }
                
                if !success {
                    ATLog(.error, "🎵 [LCPStreamingPlayer] Seek failed in queue rebuild, but continuing with playback")
                }
                
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setActive(true)
                    ATLog(.debug, "🔊 [LCPStreamingPlayer] Audio route (lazy window): \(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", "))")
                } catch {
                    ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session (lazy window): \(error)")
                }
                
                self.avQueuePlayer.play()
                self.restorePlaybackRate()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    if let self = self, !self.isLoaded {
                        self.isLoaded = true
                        self.suppressAudibleUntilPlaying = false
                        self.avQueuePlayer.isMuted = false
                    }
                }
                
                completion?(nil)
            }
        } else {
            completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Target track not found in queue"]))
        }
    }

    public override func rebuildPlayerQueueAndNavigate(
        to trackPosition: TrackPosition?,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let position = trackPosition else { completion?(false); return }
        let wasPlaying = avQueuePlayer.rate > 0
        avQueuePlayer.pause()
        (sharedResourceLoader as? LCPResourceLoaderDelegate)?.cancelAllRequests()
        isLoaded = false
        
        let allTracks = tableOfContents.allTracks
        resetPlayerQueue()
        
        guard let targetTrackIndex = allTracks.firstIndex(where: { $0.key == position.track.key }) else {
            completion?(false)
            return
        }
        
        let targetTrack = allTracks[targetTrackIndex]
        let targetItem = buildPlayerItem(for: targetTrack, index: targetTrackIndex)
        avQueuePlayer.insert(targetItem, after: nil)
        addEndObserver(for: targetItem)

        let windowSize = 5
        let startIndex = max(0, targetTrackIndex - 1)
        let endIndex = min(allTracks.count - 1, targetTrackIndex + windowSize)
        for i in startIndex...endIndex where i != targetTrackIndex {
            let track = allTracks[i]
            let item = buildPlayerItem(for: track, index: i)
            avQueuePlayer.insert(item, after: nil)
            addEndObserver(for: item)
        }
        
        let safeTs = safeTimestamp(for: position)
        let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        
        var success = false
        
        if let targetQueueIndex = avQueuePlayer.items().firstIndex(where: { $0.trackIdentifier == position.track.key }) {
            for _ in 0..<targetQueueIndex { avQueuePlayer.advanceToNextItem() }
            avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { completion?(false); return }
                if wasPlaying {
                    self.suppressAudibleUntilPlaying = true
                    self.avQueuePlayer.isMuted = true
                    self.avQueuePlayer.play()
                    self.restorePlaybackRate()
                }
                success = true
                completion?(true)
            }
        } else {
            completion?(false)
        }
    }

    public override func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) else {
            completion?(currentTrackPosition)
            return
        }

        let chapterDuration = currentChapter.duration ?? 0.0
        let offset = value * chapterDuration
        var newPosition = currentTrackPosition
        newPosition.timestamp = offset

        let safeTs = safeTimestamp(for: newPosition)
        newPosition.timestamp = safeTs
        let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] _ in
            completion?(newPosition)
            if let self, self.avQueuePlayer.rate > 0 { self.avQueuePlayer.play() }
        }
    }

    // MARK: - Helpers
    private func safeTimestamp(for position: TrackPosition) -> TimeInterval {
        let duration = position.track.duration
        
        let epsilon: TimeInterval = 0.1
        
        if position.timestamp >= duration {
            return max(0, duration - epsilon)
        }
        
        return max(0, min(position.timestamp, duration - epsilon))
    }
    
    // Build a single AVPlayerItem by concatenating multiple local parts
    private func createConcatenatedItem(from urls: [URL]) -> AVPlayerItem? {
        let composition = AVMutableComposition()
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        var currentInsertTime = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first else { continue }
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            do {
                try compositionAudioTrack.insertTimeRange(timeRange, of: track, at: currentInsertTime)
                currentInsertTime = CMTimeAdd(currentInsertTime, asset.duration)
            } catch {
                ATLog(.error, "Failed to build composition: \(error)")
                return nil
            }
        }
        return AVPlayerItem(asset: composition)
    }

    // Build a single item for a specific index using the same priority: local file -> streaming -> placeholder
    private func buildPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
        if let lcpTrack = track as? LCPTrack,
           !forceStreamingTrackKeys.contains(track.key),
           let task = lcpTrack.downloadTask as? LCPDownloadTask,
           case .saved(let urls) = task.assetFileStatus(), !urls.isEmpty {
            if urls.count == 1 {
                let asset = AVURLAsset(url: urls[0])
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .timeDomain
                item.trackIdentifier = track.key
                safeAddObserver(to: item)
                return item
            } else if let compositionItem = createConcatenatedItem(from: urls) {
                compositionItem.audioTimePitchAlgorithm = .timeDomain
                compositionItem.trackIdentifier = track.key
                safeAddObserver(to: compositionItem)
                return compositionItem
            }
        }

        let item = createStreamingPlayerItem(for: track, index: index)
        return item
    }
    
    private func createStreamingPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
        let assetURL: URL = {
            if let publication = streamingProvider?.getPublication(), index < publication.readingOrder.count {
                let readingOrderLink = publication.readingOrder[index]
                if let absoluteHref = URL(string: readingOrderLink.href), absoluteHref.scheme != nil {
                    return absoluteHref
                } else {
                    return URL(string: "readium-lcp://track\(index)/\(readingOrderLink.href)")!
                }
            } else {
                return URL(string: "fake://lcp-streaming/track/\(index)")!
            }
        }()

        let assetOptions: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: assetURL, options: assetOptions)

        if let sharedResourceLoader = sharedResourceLoader {
            objc_setAssociatedObject(asset, &Self.resourceLoaderAssocKey, sharedResourceLoader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            asset.resourceLoader.setDelegate(sharedResourceLoader, queue: resourceLoaderQueue)
        }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        item.trackIdentifier = track.key
        item.preferredForwardBufferDuration = 0.5
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        
        safeAddObserver(to: item)
        
        return item
    }


    
    // Inherit all the KVO management from LCPPlayer
    private var observedItems = Set<ObjectIdentifier>()
    private let observerQueue = DispatchQueue(label: "com.palace.lcp-streaming-observer", qos: .utility)
    
    private func safeAddObserver(to item: AVPlayerItem) {
        observerQueue.async { [weak self, weak item] in
            guard let self = self, let item = item else { return }
            let itemId = ObjectIdentifier(item)
            guard !self.observedItems.contains(itemId) else { return }
            
            item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
            self.observedItems.insert(itemId)
        }
    }
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus", let player = object as? AVQueuePlayer {
            DispatchQueue.main.async { [weak self] in
                switch player.timeControlStatus {
                case .playing:
                    self?.isLoaded = true
                    if let self = self {
                        if self.suppressAudibleUntilPlaying {
                            self.avQueuePlayer.isMuted = false
                            self.suppressAudibleUntilPlaying = false
                        }
                        if let currentKey = self.avQueuePlayer.currentItem?.trackIdentifier, self.lastStartedItemKey != currentKey {
                            self.lastStartedItemKey = currentKey
                            if let pos = self.currentTrackPosition {
                                self.playbackStatePublisher.send(.started(pos))
                            }
                        }
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self?.isLoaded = false
                    if let self = self, !self.avQueuePlayer.isMuted {
                        self.avQueuePlayer.isMuted = true
                        self.suppressAudibleUntilPlaying = true
                    }
                default:
                    break
                }
            }
            return
        }

        guard keyPath == "status",
              let item = object as? AVPlayerItem else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            let itemURL = (item.asset as? AVURLAsset)?.url.absoluteString ?? "unknown"
            
            switch item.status {
            case .readyToPlay:
                if let currentItem = self?.avQueuePlayer.currentItem, currentItem == item {
                    // Defer isLoaded to timeControlStatus changes to avoid premature hiding of loading view
                }
            case .failed:
                if let key = item.trackIdentifier {
                    self?.forceStreamingTrackKeys.insert(key)
                    self?.rebuildPlayerQueueAndNavigate(to: self?.currentTrackPosition)
                }
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }
    
    // MARK: - Chapter Position Tracking for Multi-Track Chapters
    
    @objc override func playerItemDidReachEnd(_ notification: Notification) {
        guard let endedItem = notification.object as? AVPlayerItem,
              let endedTrackKey = endedItem.trackIdentifier,
              let endedTrack = tableOfContents.track(forKey: endedTrackKey) else { 
            return 
        }
        
        let endedPosition = TrackPosition(track: endedTrack, timestamp: endedTrack.duration, tracks: tableOfContents.tracks)
        let currentChapter = try? tableOfContents.chapter(forPosition: endedPosition)
        
        if let nextTrack = tableOfContents.tracks.nextTrack(endedTrack) {
            let nextStart = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
            let nextChapter = try? tableOfContents.chapter(forPosition: nextStart)
            
            if let cur = currentChapter, let nxt = nextChapter, cur == nxt {
                let wasPlaying = avQueuePlayer.rate > 0
                
                if avQueuePlayer.items().count > 1 {
                    avQueuePlayer.advanceToNextItem()
                    if wasPlaying { 
                        avQueuePlayer.play()
                        restorePlaybackRate()
                    }
                    
                    playbackStatePublisher.send(.started(nextStart))
                } else {
                    play(at: nextStart, completion: nil)
                }
                return
            }
        } else {
            // No next track - this is end of book!
            handlePlaybackEnd(currentTrack: endedTrack, completion: nil)
            return
        }
        
        super.playerItemDidReachEnd(notification)
    }
    
    // MARK: - End of Book Handling
    
    override func handlePlaybackEnd(currentTrack: any Track, completion: ((TrackPosition?) -> Void)?) {
        // End of audiobook reached - pause and emit book completed event
        avQueuePlayer.pause()
        ATLog(.debug, "🎵 [LCPStreamingPlayer] End of book reached. No more tracks.")
        playbackStatePublisher.send(.bookCompleted)
        completion?(currentTrackPosition)
    }
    
    func publicationDidLoad() {
        ATLog(.info, "🎵 [LCPStreamingPlayer] Publication loaded - enabling streaming")
        if !isLoaded && avQueuePlayer.items().isEmpty {
            buildPlayerQueue()
        }
    }
    
    deinit {
        observerQueue.async { [observedItems] in
            // Observer cleanup happens automatically when items are deallocated
        }
        // Encourage cache cleanup between audiobook sessions
        (sharedResourceLoader as? LCPResourceLoaderDelegate)?.shutdown()
    }

    override func unload() {
        super.unload()
        (sharedResourceLoader as? LCPResourceLoaderDelegate)?.shutdown()
        streamingProvider = nil
    }
}
