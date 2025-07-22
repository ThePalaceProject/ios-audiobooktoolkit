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
    
    // MARK: - Position and State Tracking
    
    private var lastValidPosition: TrackPosition?
    private var isRecoveringFromError = false
    
    override func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Skip playhead by \(timeInterval) seconds")
        
        let referencePosition: TrackPosition?
        
        if let currentPos = currentTrackPosition {
            referencePosition = currentPos
        } else if let lastValid = lastValidPosition, isPositionStillRelevant(lastValid) {
            referencePosition = lastValid
        } else {
            referencePosition = lastKnownPosition
        }
        
        guard let position = referencePosition else {
            ATLog(.error, "[LCPStreaming] No reference position available for skip")
            if let firstTrack = tableOfContents.allTracks.first {
                let fallbackPosition = TrackPosition(
                    track: firstTrack,
                    timestamp: 0.0,
                    tracks: tableOfContents.tracks
                )
                navigateToStreamingPosition(fallbackPosition, completion: completion)
            } else {
                completion?(nil)
            }
            return
        }
        
        let newPosition = position + timeInterval
        ATLog(.debug, "[LCPStreaming] Calculated new position: track \(newPosition.track.key), timestamp: \(newPosition.timestamp)")
        
        if let validatedPosition = validateAndCorrectPosition(newPosition, skipInterval: timeInterval, fromPosition: position) {
            updatePositionTracking(validatedPosition)
            navigateToStreamingPosition(validatedPosition, completion: completion)
        } else {
            ATLog(.error, "[LCPStreaming] Could not validate position for skip")
            completion?(nil)
        }
    }
    
    /// Validates that a stored position is still relevant to the current playback context
    private func isPositionStillRelevant(_ position: TrackPosition) -> Bool {
        if let currentTrack = currentTrackPosition?.track {
            return currentTrack.key == position.track.key
        }
        return tableOfContents.allTracks.contains(where: { $0.key == position.track.key })
    }
    
    /// Validates and corrects a position to ensure it's within valid boundaries
    private func validateAndCorrectPosition(_ position: TrackPosition, skipInterval: TimeInterval, fromPosition: TrackPosition) -> TrackPosition? {
        // First check if position is within a valid chapter
        if let _ = try? tableOfContents.chapter(forPosition: position) {
            return position
        }
        
        // Handle edge cases where position is outside valid boundaries
        if position.track.index >= tableOfContents.allTracks.count - 1 && 
           position.timestamp >= position.track.duration {
            // Clamp to end of book
            let lastTrack = tableOfContents.allTracks.last!
            return TrackPosition(track: lastTrack, timestamp: lastTrack.duration, tracks: position.tracks)
        }
        
        if position.track.index <= 0 && position.timestamp <= 0 {
            // Clamp to beginning of book
            let firstTrack = tableOfContents.allTracks.first!
            return TrackPosition(track: firstTrack, timestamp: 0.0, tracks: position.tracks)
        }
        
        // Find nearest valid chapter
        let allChapters = tableOfContents.toc
        if let nearestChapter = allChapters.min(by: { chapter1, chapter2 in
            let dist1 = abs(chapter1.position.track.index - position.track.index)
            let dist2 = abs(chapter2.position.track.index - position.track.index)
            return dist1 < dist2
        }) {
            return nearestChapter.position
        }
        
        return position
    }
    
    /// Optimized position navigation that handles both intra-track and cross-track seeks
    private func navigateToStreamingPosition(_ position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Navigating to position: track \(position.track.key), timestamp: \(position.timestamp)")
        
        // Check if we're already on the correct track
        if let currentItem = avQueuePlayer.currentItem,
           currentItem.trackIdentifier == position.track.key {
            // Simple seek within current track
            performStreamingSeek(to: position.timestamp, completion: completion)
            return
        }
        
        // Check if the target track is already in the queue
        let queueItems = avQueuePlayer.items()
        if let targetIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
            // Navigate to existing item in queue
            navigateToExistingQueueItem(at: targetIndex, position: position, completion: completion)
            return
        }
        
        // Need to load new track - this is the expensive operation we want to minimize
        loadAndNavigateToTrack(position, completion: completion)
    }
    
    private func performStreamingSeek(to timestamp: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        let seekTime = CMTime(seconds: timestamp, preferredTimescale: 1000)
        
        avQueuePlayer.seek(to: seekTime) { [weak self] success in
            guard let self = self else {
                completion?(nil)
                return
            }
            
            if success {
                let newPosition = self.currentTrackPosition
                ATLog(.debug, "[LCPStreaming] Seek successful to \(timestamp), new position: \(newPosition?.timestamp ?? -1)")
                
                if let position = newPosition {
                    self.updatePositionTracking(position)
                }
                
                completion?(newPosition)
            } else {
                ATLog(.error, "[LCPStreaming] Seek failed to \(timestamp)")
                completion?(self.currentTrackPosition)
            }
        }
    }
    
    private func navigateToExistingQueueItem(at index: Int, position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        let wasPlaying = avQueuePlayer.rate > 0
        avQueuePlayer.pause()
        
        // Navigate to the target item
        let currentIndex = avQueuePlayer.items().firstIndex(of: avQueuePlayer.currentItem!) ?? 0
        
        if index < currentIndex {
            // Need to rebuild queue to go backwards
            rebuildQueueForTrack(at: index, timestamp: position.timestamp, completion: completion)
        } else {
            // Can advance forward in queue
            for _ in currentIndex..<index {
                avQueuePlayer.advanceToNextItem()
            }
            
            // Seek to the desired timestamp
            let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: 1000)
            avQueuePlayer.seek(to: seekTime) { [weak self] success in
                if success && wasPlaying {
                    self?.avQueuePlayer.play()
                }
                
                let newPosition = self?.currentTrackPosition
                completion?(success ? newPosition : nil)
            }
        }
    }
    
    private func rebuildQueueForTrack(at index: Int, timestamp: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        let tracks = tableOfContents.allTracks
        guard index < tracks.count else {
            completion?(nil)
            return
        }
        
        let targetTrack = tracks[index]
        let targetPosition = TrackPosition(track: targetTrack, timestamp: timestamp, tracks: tableOfContents.tracks)
        loadAndNavigateToTrack(targetPosition, completion: completion)
    }
    
    private func loadAndNavigateToTrack(_ position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Loading and navigating to track: \(position.track.key)")
        
        // Clear current queue
        resetPlayerQueue()
        
        // Load the new track
        insertStreamingTrackIntoQueue(track: position.track) { [weak self] success in
            guard let self = self else {
                completion?(nil)
                return
            }
            
            if success {
                // After loading, seek to the desired position
                self.performStreamingSeek(to: position.timestamp, completion: completion)
            } else {
                ATLog(.error, "[LCPStreaming] Failed to load streaming track: \(position.track.key)")
                completion?(nil)
            }
        }
    }
    
    override func play() {
        ATLog(.debug, "[LCPStreaming] Play requested - checking current state")
        
        // Try to get current position, fall back to last valid position
        let referencePosition = currentTrackPosition ?? lastValidPosition ?? lastKnownPosition
        
        guard let position = referencePosition else {
            ATLog(.error, "[LCPStreaming] No position available for play - starting from beginning")
            // Fall back to first track if no position available
            if let firstTrack = tableOfContents.allTracks.first {
                let fallbackPosition = TrackPosition(
                    track: firstTrack,
                    timestamp: 0.0,
                    tracks: tableOfContents.tracks
                )
                play(at: fallbackPosition, completion: nil)
            }
            return
        }
        
        // If we have a position, use it to resume playback
        isRecoveringFromError = true
        ATLog(.debug, "[LCPStreaming] Resuming playback from position: \(position.track.key), timestamp: \(position.timestamp)")
        play(at: position, completion: nil)
    }
    
    override func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Playing at position: \(position.track.key), timestamp: \(position.timestamp)")
        
        // Store as last valid position
        lastValidPosition = position
        
        // Use our streaming navigation logic
        navigateToStreamingPosition(position) { [weak self] trackPosition in
            guard let self = self else {
                completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Player deallocated"]))
                return
            }
            
            if let trackPosition = trackPosition {
                // Update position tracking
                self.updatePositionTracking(trackPosition)
                
                // Start playback
                self.avQueuePlayer.play()
                self.restorePlaybackRate()
                completion?(nil)
            } else {
                completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to navigate to position"]))
            }
        }
    }
    
    override func pause() {
        ATLog(.debug, "[LCPStreaming] Pause requested")
        
        // Store current position before pausing
        if let currentPos = currentTrackPosition {
            lastValidPosition = currentPos
        }
        
        avQueuePlayer.pause()
        clearPositionCache()
    }
    
    override func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Moving to progress value: \(value)")
        
        let referencePosition = currentTrackPosition ?? (isRecoveringFromError ? nil : lastValidPosition)
        
        guard let currentPos = referencePosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentPos) else {
            ATLog(.error, "[LCPStreaming] Cannot move - no valid current position or chapter")
            completion?(nil)
            return
        }
        
        let chapterDuration = currentChapter.duration ?? currentChapter.position.track.duration
        let targetPosition = currentChapter.position + value * chapterDuration
        
        ATLog(.debug, "[LCPStreaming] Chapter-aware move: target=\(targetPosition.track.key)@\(targetPosition.timestamp)")
        
        updatePositionTracking(targetPosition)
        navigateToStreamingPosition(targetPosition, completion: completion)
    }
    
    private func restorePlaybackRate() {
        avQueuePlayer.rate = PlaybackRate.convert(rate: playbackRate)
    }
    
    private func updatePositionTracking(_ position: TrackPosition?) {
        if let position = position {
            lastValidPosition = position
            isRecoveringFromError = false
        }
    }
    
    override func resetPlayerQueue() {
        for item in avQueuePlayer.items() {
            item.removeObserver(self, forKeyPath: "status")
        }
        avQueuePlayer.removeAllItems()
        ATLog(.debug, "[LCPStreaming] Player queue reset")
    }
    
    override func handlePlaybackEnd(currentTrack: any Track, completion: ((TrackPosition?) -> Void)?) {
        ATLog(.debug, "[LCPStreaming] Handling playback end for track: \(currentTrack.key)")
        
        // Check if there's a next track
        if let nextTrack = tableOfContents.tracks.nextTrack(currentTrack) {
            ATLog(.debug, "[LCPStreaming] Moving to next track: \(nextTrack.key)")
            
            // Navigate to the beginning of the next track
            let nextPosition = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
            
            navigateToStreamingPosition(nextPosition) { [weak self] trackPosition in
                guard let self = self else {
                    completion?(nil)
                    return
                }
                
                if let position = trackPosition {
                    ATLog(.debug, "[LCPStreaming] Successfully navigated to next track")
                    // Continue playing automatically
                    self.avQueuePlayer.play()
                    self.restorePlaybackRate()
                    completion?(position)
                } else {
                    ATLog(.error, "[LCPStreaming] Failed to navigate to next track")
                    completion?(nil)
                }
            }
        } else {
            ATLog(.debug, "[LCPStreaming] Reached end of book")
            
            // Truly at the end of the book - stay at the last position
            let endPosition = TrackPosition(
                track: currentTrack,
                timestamp: currentTrack.duration,
                tracks: tableOfContents.tracks
            )
            
            avQueuePlayer.pause()
            playbackStatePublisher.send(.bookCompleted)
            completion?(endPosition)
        }
    }
    
    @objc override func playerItemDidReachEnd(_ notification: Notification) {
        ATLog(.debug, "[LCPStreaming] Player item reached end")
        
        guard let currentTrack = currentTrackPosition?.track else {
            ATLog(.error, "[LCPStreaming] No current track when item reached end")
            return
        }
        
        // Send chapter completed event if we can determine the current chapter
        if let currentTrackPosition = currentTrackPosition,
           let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) {
            playbackStatePublisher.send(.completed(currentChapter))
        }
        
        // Handle the transition to next track using our streaming logic
        handlePlaybackEnd(currentTrack: currentTrack, completion: nil)
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
                
                // Preserve current position before handling the error
                if let currentPos = currentTrackPosition {
                    lastValidPosition = currentPos
                    ATLog(.debug, "[LCPStreaming] Preserved position during failure: \(currentPos.track.key), timestamp: \(currentPos.timestamp)")
                }
                
                // Mark that we're in an error state to prevent incorrect position usage
                isRecoveringFromError = true
                
                // Try to determine a reasonable position for the error
                let errorPosition: TrackPosition?
                if let currentPosition = currentTrackPosition ?? lastValidPosition {
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

private struct AssociatedKeys {
    static var trackIdentifier = "trackIdentifier"
} 

