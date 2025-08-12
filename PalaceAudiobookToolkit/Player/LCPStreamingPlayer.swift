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
    
    override var currentOffset: Double {
        guard let currentTrackPosition, let currentChapter else {
            return 0
        }
        
        let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
        return offset
    }
    
    init(tableOfContents: AudiobookTableOfContents, drmDecryptor: DRMDecryptor? = nil) {
        super.init(tableOfContents: tableOfContents)
        
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        fatalError("init(tableOfContents:) has not been implemented")
    }
    
    /// Set the streaming provider for resource loading
    func setStreamingProvider(_ provider: StreamingResourceProvider) {
        self.streamingProvider = provider
        // Rebuild player queue with custom URLs now that we have the provider
        if tableOfContents.tracks.first != nil { buildPlayerQueue() }
    }

    // Delay building the queue until the streaming provider is set, to ensure
    // assets are created with a valid resource loader delegate from the start.
    override func configurePlayer() {
        setupAudioSession()
        // Intentionally do NOT call buildPlayerQueue() here.
    }
    
    /// Build player items using custom lcp:// URLs
    public override func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
        var items = [AVPlayerItem]()
        
        for (index, track) in tracks.enumerated() {
            // If local decrypted files exist, prefer local playback for that item
            if let lcpTrack = track as? LCPTrack, lcpTrack.hasLocalFiles(),
               let urls = (lcpTrack.downloadTask as? LCPDownloadTask)?.decryptedUrls, !urls.isEmpty {
                let localItem = AVPlayerItem(url: urls[0])
                localItem.audioTimePitchAlgorithm = .timeDomain
                localItem.trackIdentifier = track.key
                items.append(localItem)
            } else {
                let item = createStreamingPlayerItem(for: track, index: index)
                items.append(item)
            }
        }
        
        return items
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
            let publication = provider.getPublication()
            let resourceLoader = LCPResourceLoaderDelegate(publication: publication)
            
            // CRITICAL: Store the resource loader to prevent deallocation AND set delegate immediately
            objc_setAssociatedObject(asset, &Self.resourceLoaderAssocKey, resourceLoader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoaderQueue)
            
            // Force asset to start loading metadata which should trigger resource loader
            Task {
                _ = try? await asset.load(.isPlayable)
            }
        } else {
            
        }
        
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        item.trackIdentifier = track.key
        
        // Add KVO observer safely
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
            switch item.status {
            case .readyToPlay:
                break
            case .failed:
                if let err = item.error as NSError? {
                    ATLog(.error, "Playback failed: \(err.domain) \(err.code) - \(err.localizedDescription)")
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
