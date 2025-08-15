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
    private var forceStreamingTrackKeys = Set<String>()
    private let compositionQueue = DispatchQueue(label: "com.palace.lcp.local-composition", qos: .userInitiated)
    
    private var sharedResourceLoader: LCPResourceLoaderDelegate?
    
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
        buildPlayerQueue()
        addPlayerObservers()
        
        avQueuePlayer.actionAtItemEnd = .none
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = false
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
                    // Concatenate multiple decrypted parts into a single composition item
                    if let compositionItem = createConcatenatedItem(from: urls) {
                        localItem = compositionItem
                    } else {
                        let item = createStreamingPlayerItem(for: track, index: index)
                        items.append(item)
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
                ATLog(.debug, "🎵 Created STREAMING item for track \(index): fake://lcp-streaming/track/\(index)")
            }
        }
        
        self.isLoaded = true
        return items
    }

    // MARK: - Navigation aligned with LCPPlayer

    public override func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
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
                avQueuePlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    // Ensure session is active before resuming
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setActive(true)
                        
                        let route = session.currentRoute
                    } catch {
                        ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session: \(error)")
                    }
                    
                    self?.avQueuePlayer.play()
                    self?.restorePlaybackRate()
                    var startedPos = position
                    startedPos.timestamp = safeTs
                    self?.playbackStatePublisher.send(.started(startedPos))
                    completion?(nil)
                }
                return
            }
        }

        let allTracks = tableOfContents.allTracks
        let newItems = buildPlayerItems(fromTracks: allTracks)
        avQueuePlayer.removeAllItems()
        
        // Find target track index for windowing
        let targetTrackIndex = allTracks.firstIndex { $0.key == position.track.key } ?? 0
        
        // Add a window of items around the target track
        let windowSize = 5
        let startIndex = max(0, targetTrackIndex - 1)
        let endIndex = min(newItems.count, targetTrackIndex + windowSize)
        
        for i in startIndex..<endIndex {
            avQueuePlayer.insert(newItems[i], after: nil)
        }
        var queueItems = avQueuePlayer.items()

        if let targetIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
            // Ensure items exist up to target before advancing
            while avQueuePlayer.items().count <= targetIndex, let next = newItems.dropFirst(avQueuePlayer.items().count).first {
                avQueuePlayer.insert(next, after: nil)
            }
            for _ in 0..<targetIndex { avQueuePlayer.advanceToNextItem() }
            let safeTs = safeTimestamp(for: position)
            let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            avQueuePlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setActive(true)
                    ATLog(.debug, "🔊 [LCPStreamingPlayer] Audio route (fallback): \(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", "))")
                } catch {
                    ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session (fallback): \(error)")
                }
                self?.avQueuePlayer.play()
                self?.restorePlaybackRate()
                var startedPos = position
                startedPos.timestamp = safeTs
                self?.playbackStatePublisher.send(.started(startedPos))
                completion?(nil)
            }
        } else {
            if targetTrackIndex < newItems.count {
                avQueuePlayer.insert(newItems[targetTrackIndex], after: nil)
                
                queueItems = avQueuePlayer.items()
                if let targetIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
                    for _ in 0..<targetIndex { avQueuePlayer.advanceToNextItem() }
                    let safeTs = safeTimestamp(for: position)
                    let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                    avQueuePlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        do {
                            let session = AVAudioSession.sharedInstance()
                            try session.setActive(true)
                            ATLog(.debug, "🔊 [LCPStreamingPlayer] Audio route (fallback 2): \(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", "))")
                        } catch {
                            ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session (fallback 2): \(error)")
                        }
                        self?.avQueuePlayer.play()
                        self?.restorePlaybackRate()
                        var startedPos = position
                        startedPos.timestamp = safeTs
                        self?.playbackStatePublisher.send(.started(startedPos))
                        completion?(nil)
                    }
                } else {
                    completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Target track not found in queue"]))
                }
            } else {
                completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Target track index out of bounds"]))
            }
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
        avQueuePlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            completion?(newPosition)
            if let self, self.avQueuePlayer.rate > 0 { self.avQueuePlayer.play() }
        }
    }

    // MARK: - Helpers
    private func safeTimestamp(for position: TrackPosition) -> TimeInterval {
        let duration = position.track.duration
        let epsilon: TimeInterval = 0.5
        if position.timestamp >= duration {
            return max(0, duration - epsilon)
        }
        if duration - position.timestamp < 0.25 {
            return max(0, duration - epsilon)
        }
        return max(0, position.timestamp)
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
    
    private func createStreamingPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
        guard let publication = streamingProvider?.getPublication(),
              index < publication.readingOrder.count else {
            let customUrl = URL(string: "fake://lcp-streaming/track/\(index)")!
            let asset = AVURLAsset(url: customUrl, options: [:])
            return AVPlayerItem(asset: asset)
        }
        
        let readingOrderLink = publication.readingOrder[index]
        let realHttpUrl: URL
        
        if let absoluteHref = URL(string: readingOrderLink.href), absoluteHref.scheme != nil {
            realHttpUrl = absoluteHref
                } else {
            let readiumLcpUrl = URL(string: "readium-lcp://track\(index)/\(readingOrderLink.href)")!
            realHttpUrl = readiumLcpUrl
        }
        
        let assetOptions: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: realHttpUrl, options: assetOptions)
        
        if let sharedResourceLoader = sharedResourceLoader {
            objc_setAssociatedObject(asset, &Self.resourceLoaderAssocKey, sharedResourceLoader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            asset.resourceLoader.setDelegate(sharedResourceLoader, queue: resourceLoaderQueue)
        }
        
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        item.trackIdentifier = track.key
        item.preferredForwardBufferDuration = 0.1
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
                    let isPlaying = self?.avQueuePlayer.timeControlStatus == .playing
                    let rate = self?.avQueuePlayer.rate ?? 0
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
        }
        
        super.playerItemDidReachEnd(notification)
    }
    
    deinit {
        observerQueue.async { [observedItems] in
            // Observer cleanup happens automatically when items are deallocated
        }
    }
}
