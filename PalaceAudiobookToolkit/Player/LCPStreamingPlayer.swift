//
//  LCPStreamingPlayer.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import Combine
import ReadiumShared

/// LCPStreamingPlayer provides true HTTP-byte-range streaming for LCP audiobooks
/// without pre-downloading and decrypting entire track files
class LCPStreamingPlayer: OpenAccessPlayer {
    
    private var resourceLoaderDelegate: LCPResourceLoaderDelegate?
    private var httpRangeRetriever: HTTPRangeRetriever?
    private let lcpDecryptor: DRMDecryptor
    private let lcpPublication: Publication
    private let streamingQueue = DispatchQueue(label: "com.palace.lcp-streaming", qos: .userInitiated)
    
    override var taskCompleteNotification: Notification.Name {
        LCPStreamingTaskCompleteNotification
    }
    
    override var currentOffset: Double {
        guard let currentTrackPosition, let currentChapter else {
            return 0
        }
        
        let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
        return offset
    }
    
    init(
        tableOfContents: AudiobookTableOfContents,
        decryptor: DRMDecryptor,
        publication: Publication,
        rangeRetriever: HTTPRangeRetriever? = nil
    ) {
        self.lcpDecryptor = decryptor
        self.lcpPublication = publication
        self.httpRangeRetriever = rangeRetriever ?? HTTPRangeRetriever()
        
        super.init(tableOfContents: tableOfContents)
        
        setupResourceLoader()
        configurePlayer()
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        // This initializer shouldn't be used for streaming, but we need it for protocol conformance
        fatalError("LCPStreamingPlayer requires a decryptor and publication. Use init(tableOfContents:decryptor:publication:) instead.")
    }
    
    override func configurePlayer() {
        setupAudioSession()
        loadInitialPlayerQueue()
        addPlayerObservers()
    }
    
    // MARK: - Resource Loader Setup
    
    private func setupResourceLoader() {
        guard let httpRangeRetriever = httpRangeRetriever else {
            ATLog(.error, "[LCPStreaming] No HTTP range retriever available")
            return
        }
        
        resourceLoaderDelegate = LCPResourceLoaderDelegate(
            httpRangeRetriever: httpRangeRetriever,
            lcpPublication: lcpPublication
        )
        
        ATLog(.debug, "[LCPStreaming] Resource loader delegate configured")
    }
    
    // MARK: - Player Queue Management
    
    private func loadInitialPlayerQueue() {
        resetPlayerQueue()
        
        guard let firstTrack = tableOfContents.allTracks.first else {
            isLoaded = false
            return
        }
        
        // For streaming, we don't need to decrypt tracks beforehand
        insertStreamingTrackIntoQueue(track: firstTrack) { [weak self] success in
            guard let self = self else { return }
            self.isLoaded = success
        }
    }
    
    private func insertStreamingTrackIntoQueue(track: any Track, completion: @escaping (Bool) -> Void) {
        guard let streamingTask = track.downloadTask as? LCPStreamingDownloadTask else {
            ATLog(.error, "[LCPStreaming] Track does not have a streaming download task: \(track.key)")
            completion(false)
            return
        }
        
        guard let streamingUrls = streamingTask.streamingUrls, !streamingUrls.isEmpty else {
            ATLog(.error, "[LCPStreaming] No streaming URLs available for track: \(track.key)")
            completion(false)
            return
        }
        
        ATLog(.debug, "[LCPStreaming] Creating streaming player items for track: \(track.key)")
        
        let playerItems = createStreamingPlayerItems(for: streamingUrls, trackKey: track.key)
        
        if playerItems.isEmpty {
            ATLog(.error, "[LCPStreaming] Failed to create player items for track: \(track.key)")
            completion(false)
            return
        }
        
        // Add items to the player queue
        for item in playerItems {
            avQueuePlayer.insert(item, after: nil)
        }
        
        ATLog(.debug, "[LCPStreaming] Successfully added \(playerItems.count) streaming items for track: \(track.key)")
        completion(true)
    }
    
    private func createStreamingPlayerItems(for urls: [URL], trackKey: String) -> [AVPlayerItem] {
        guard let resourceLoaderDelegate = resourceLoaderDelegate else {
            ATLog(.error, "[LCPStreaming] No resource loader delegate available")
            return []
        }
        
        var playerItems: [AVPlayerItem] = []
        
        for url in urls {
            // Create AVURLAsset with custom scheme
            let asset = AVURLAsset(url: url)
            
            // Set our custom resource loader
            asset.resourceLoader.setDelegate(
                resourceLoaderDelegate,
                queue: streamingQueue
            )
            
            // Create player item
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.audioTimePitchAlgorithm = .timeDomain
            playerItem.trackIdentifier = trackKey
            
            // Add status observer for debugging
            playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
            
            playerItems.append(playerItem)
            
            ATLog(.debug, "[LCPStreaming] Created streaming player item for URL: \(url.absoluteString)")
        }
        
        return playerItems
    }
    
    // MARK: - Track Management
    
    override func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        // For streaming, we use the same skip logic as the base class
        super.skipPlayhead(timeInterval, completion: completion)
    }
    
    override func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Playing at position: \(position)")
        
        // Find the track for this position
        guard let track = tableOfContents.allTracks.first(where: { $0.key == position.track.key }) else {
            completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Track not found"]))
            return
        }
        
        // For streaming, we don't need to wait for decryption
        insertStreamingTrackIntoQueue(track: track) { [weak self] success in
            guard let self = self else { return }
            
            if success {
                // Seek to the specific time within the track
                let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: 1000)
                self.avQueuePlayer.seek(to: seekTime) { finished in
                    completion?(finished ? nil : NSError(domain: "LCPStreamingPlayer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Seek failed"]))
                }
            } else {
                completion?(NSError(domain: "LCPStreamingPlayer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to load streaming track"]))
            }
        }
    }
    
    // MARK: - Asset Status Handling
    
    override func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        guard let streamingTask = task as? LCPStreamingDownloadTask else {
            return .unknown
        }
        
        // For streaming tasks, we're always ready if streaming is enabled
        return streamingTask.assetFileStatus()
    }
    
    // MARK: - Observer Handling
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let item = object as? AVPlayerItem {
            handlePlayerItemStatusChange(item: item)
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func handlePlayerItemStatusChange(item: AVPlayerItem) {
        let trackKey = item.trackIdentifier ?? "unknown"
        
        switch item.status {
        case .readyToPlay:
            ATLog(.debug, "[LCPStreaming] Player item ready to play: \(trackKey)")
            
        case .failed:
            if let error = item.error {
                ATLog(.error, "[LCPStreaming] Player item failed: \(trackKey)")
                ATLog(.error, "[LCPStreaming] Error: \(error.localizedDescription)")
                ATLog(.error, "[LCPStreaming] Error details: \(error)")
                
                // Try to determine a reasonable position for the error
                let errorPosition: TrackPosition?
                if let currentPosition = currentTrackPosition {
                    errorPosition = currentPosition
                } else if let track = tableOfContents.allTracks.first(where: { $0.key == trackKey }) {
                    // Create a position at the beginning of the failed track
                    errorPosition = TrackPosition(track: track, timestamp: 0.0, tracks: tableOfContents.tracks)
                    ATLog(.debug, "[LCPStreaming] Created error position for track: \(trackKey)")
                } else {
                    errorPosition = nil
                    ATLog(.debug, "[LCPStreaming] Could not determine position for failed track: \(trackKey)")
                }
                
                // Send error state
                playbackStatePublisher.send(.failed(errorPosition, error))
            }
            
        case .unknown:
            ATLog(.debug, "[LCPStreaming] Player item status unknown: \(trackKey)")
            
        @unknown default:
            ATLog(.debug, "[LCPStreaming] Player item status unknown default: \(trackKey)")
        }
    }
    
    // MARK: - Cleanup
    
    deinit {
        // Clean up resource loader
        resourceLoaderDelegate = nil
        httpRangeRetriever = nil
        
        ATLog(.debug, "[LCPStreaming] LCPStreamingPlayer deallocated")
    }
}

// MARK: - Track Prefetching

extension LCPStreamingPlayer {
    
    /// Prefetch the next track for smoother playback transitions
    /// For streaming, this might involve preloading some initial bytes
    private func prefetchNextTrack(from currentTrack: any Track) {
        guard let nextTrack = tableOfContents.tracks.nextTrack(currentTrack) else {
            ATLog(.debug, "[LCPStreaming] No next track to prefetch")
            return
        }
        
        ATLog(.debug, "[LCPStreaming] Prefetching next track: \(nextTrack.key)")
        
        // For streaming, we can optionally preload the first few KB of the next track
        // to ensure smooth transitions. This is optional and can be implemented later.
        
        // Example: Preload first 64KB of next track
        prefetchTrackHead(track: nextTrack, bytes: 64 * 1024)
    }
    
    private func prefetchTrackHead(track: any Track, bytes: Int) {
        guard let streamingTask = track.downloadTask as? LCPStreamingDownloadTask,
              let originalUrl = streamingTask.originalUrls.first else {
            return
        }
        
        // This would use the HTTPRangeRetriever to fetch the first N bytes
        // Implementation can be added for performance optimization
        ATLog(.debug, "[LCPStreaming] Would prefetch \(bytes) bytes of track: \(track.key)")
    }
}

// MARK: - AVPlayerItem Extension
//
//private extension AVPlayerItem {
//    var trackIdentifier: String? {
//        get {
//            return objc_getAssociatedObject(self, &AssociatedKeys.trackIdentifier) as? String
//        }
//        set {
//            objc_setAssociatedObject(self, &AssociatedKeys.trackIdentifier, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
//        }
//    }
//}

private struct AssociatedKeys {
    static var trackIdentifier = "trackIdentifier"
} 

