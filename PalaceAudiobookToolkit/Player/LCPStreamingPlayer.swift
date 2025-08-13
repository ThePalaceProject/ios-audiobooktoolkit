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
    
    private weak var streamingProvider: StreamingResourceProvider?
    private let resourceLoaderQueue = DispatchQueue(label: "com.palace.lcp-streaming-loader", qos: .userInitiated)
    private static var resourceLoaderAssocKey: UInt8 = 0
    private let decryptionDelegate: DRMDecryptor?
    private var forceStreamingTrackKeys = Set<String>()
    private let compositionQueue = DispatchQueue(label: "com.palace.lcp.local-composition", qos: .userInitiated)
    
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
    
    /// Set the streaming provider for resource loading
    func setStreamingProvider(_ provider: StreamingResourceProvider) {
        self.streamingProvider = provider
        if tableOfContents.tracks.first != nil { buildPlayerQueue() }
    }

    override func configurePlayer() {
        setupAudioSession()
        avQueuePlayer.actionAtItemEnd = .none
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
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
                    ATLog(.debug, "🎵 Created LOCAL item for track \(index): \(urls[0])")
                } else {
                    // Concatenate multiple decrypted parts into a single composition item
                    if let compositionItem = createConcatenatedItem(from: urls) {
                        localItem = compositionItem
                        ATLog(.debug, "🎵 Created LOCAL COMPOSITION for track \(index) with \(urls.count) parts")
                    } else {
                        let item = createStreamingPlayerItem(for: track, index: index)
                        items.append(item)
                        ATLog(.debug, "🎵 Fallback STREAMING item for track \(index): fake://lcp-streaming/track/\(index)")
                        continue
                    }
                }
                localItem.audioTimePitchAlgorithm = .spectral
                localItem.trackIdentifier = track.key
                items.append(localItem)
                safeAddObserver(to: localItem)
            } else {
                let item = createStreamingPlayerItem(for: track, index: index)
                items.append(item)
                ATLog(.debug, "🎵 Created STREAMING item for track \(index): fake://lcp-streaming/track/\(index)")
            }
        }
        
        return items
    }

    // MARK: - Navigation aligned with LCPPlayer

    public override func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        var needsRebuild = avQueuePlayer.items().isEmpty

        if !needsRebuild {
            if let targetIndex = avQueuePlayer.items().firstIndex(where: { $0.trackIdentifier == position.track.key }) {
                let item = avQueuePlayer.items()[targetIndex]
                // Treat file URL assets and composition assets as local
                let isCurrentlyLocal: Bool = {
                    if let urlAsset = item.asset as? AVURLAsset { return urlAsset.url.isFileURL }
                    // Non-URL assets (e.g. AVComposition from concatenated parts) are local
                    return !(item.asset is AVURLAsset)
                }()
                if let lcpTrack = position.track as? LCPTrack {
                    let shouldBeLocal = lcpTrack.hasLocalFiles() && !forceStreamingTrackKeys.contains(lcpTrack.key)
                    if shouldBeLocal != isCurrentlyLocal {
                        needsRebuild = true
                    }
                }
            } else {
                // Target not present in current queue → rebuild
                needsRebuild = true
            }
        }

        if !needsRebuild {
            // Navigate within the existing queue
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
                    try? AVAudioSession.sharedInstance().setActive(true)
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
        for (i, item) in newItems.enumerated() {
            // Insert only a window to reduce simultaneous streaming starts
            if i < 3 { avQueuePlayer.insert(item, after: nil) }
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
                try? AVAudioSession.sharedInstance().setActive(true)
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
    
    /// Create player item with custom lcp:// URL and resource loader
    private func createStreamingPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
        // Use fake scheme that AVFoundation will definitely pass to resource loader
        let customUrl = URL(string: "fake://lcp-streaming/track/\(index)")!
        
        // Create asset with options that force resource loading
        let assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        let asset = AVURLAsset(url: customUrl, options: assetOptions)
        
        // Set up resource loader delegate BEFORE creating player item
        if let provider = streamingProvider {
            let resourceLoader = LCPResourceLoaderDelegate(provider: provider)
            
            // CRITICAL: Store the resource loader to prevent deallocation AND set delegate immediately
            objc_setAssociatedObject(asset, &Self.resourceLoaderAssocKey, resourceLoader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoaderQueue)
            
            // Do not prefetch metadata for all items; let the current item trigger loading on demand
        } else {
            
        }
        
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        item.trackIdentifier = track.key
        item.preferredForwardBufferDuration = 0.1
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        
        // Add KVO observer safely
        safeAddObserver(to: item)
        
        return item
    }

    private func maybeDecryptInBackground(originalHref: URL, destination: URL) {
        guard let decryptor = decryptionDelegate else { return }
        // Use file URL with path equal to manifest href for Readium lookup
        let source = URL(fileURLWithPath: originalHref.path)
        decryptor.decrypt(url: source, to: destination) { [weak self] _ in
            guard let self else { return }
            // If current queue contains a streaming item for this href, rebuild to use local
            DispatchQueue.main.async {
                let needsSwap = self.avQueuePlayer.items().contains { item in
                    guard let key = item.trackIdentifier else { return false }
                    return key == originalHref.absoluteString || key == originalHref.path
                }
                if needsSwap {
                    self.rebuildPlayerQueueAndNavigate(to: self.currentTrackPosition)
                }
            }
        }
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
            switch item.status {
            case .readyToPlay:
                break
            case .failed:
                if let err = item.error as NSError? {
                    ATLog(.error, "Playback failed: \(err.domain) \(err.code) - \(err.localizedDescription)")
                }
                // If this item failed, force streaming for this track key and rebuild
                if let key = item.trackIdentifier {
                    ATLog(.warn, "Forcing streaming for failed track key=\(key)")
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
    
    deinit {
        observerQueue.async { [observedItems] in
            // Observer cleanup happens automatically when items are deallocated
            ATLog(.debug, "🎵 [LCPStreamingPlayer] Deinit with \(observedItems.count) observed items")
        }
    }
}
