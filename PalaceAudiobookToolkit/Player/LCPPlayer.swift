//
//  LCPPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/16/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import ReadiumShared

class LCPPlayer: OpenAccessPlayer {
    
    var decryptionDelegate: DRMDecryptor?
    private let decryptionQueue = DispatchQueue(label: "com.palace.LCPPlayer.decryptionQueue", qos: .background)
    private var isActive: Bool = true
    
    private var hasStartedPrioritizedDownloads = false
    private var isNavigating = false
    private var trackToItemMapping: [String: [AVPlayerItem]] = [:]
    private var queueBuiltSuccessfully = false
    private var queueMonitoringTimer: Timer?
    private var lastQueueRestoreTime: Date = Date.distantPast
    private var isUpdatingCurrentItem = false
    private var observedItems = Set<ObjectIdentifier>()
    private let observerQueue = DispatchQueue(label: "LCPPlayer.observers", qos: .userInitiated)
    
    override var taskCompleteNotification: Notification.Name {
        LCPDownloadTaskCompleteNotification
    }
    
    // MARK: - Thread-Safe Observer Management
    
    /// Safely add KVO observer to AVPlayerItem if not already observing
    private func safeAddObserver(to item: AVPlayerItem) {
        observerQueue.sync {
            let itemId = ObjectIdentifier(item)
            guard !observedItems.contains(itemId) else {
                ATLog(.debug, "🎵 [LCPPlayer] Observer already exists for item: \(item.trackIdentifier ?? "unknown")")
                return
            }
            
            do {
                item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
                observedItems.insert(itemId)
                ATLog(.debug, "🎵 [LCPPlayer] ✅ Added observer for item: \(item.trackIdentifier ?? "unknown")")
            } catch {
                ATLog(.error, "🎵 [LCPPlayer] ❌ Failed to add observer: \(error)")
            }
        }
    }
    
    /// Safely remove KVO observer from AVPlayerItem if currently observing
    private func safeRemoveObserver(from item: AVPlayerItem) {
        observerQueue.sync {
            let itemId = ObjectIdentifier(item)
            guard observedItems.contains(itemId) else {
                ATLog(.debug, "🎵 [LCPPlayer] No observer to remove for item: \(item.trackIdentifier ?? "unknown")")
                return
            }
            
            do {
                item.removeObserver(self, forKeyPath: "status", context: nil)
                observedItems.remove(itemId)
                ATLog(.debug, "🎵 [LCPPlayer] ✅ Removed observer for item: \(item.trackIdentifier ?? "unknown")")
            } catch {
                ATLog(.error, "🎵 [LCPPlayer] ❌ Failed to remove observer: \(error)")
            }
        }
    }
    
    /// Safely remove all observers from all tracked items
    private func safeRemoveAllObservers() {
        observerQueue.sync {
            for item in avQueuePlayer.items() {
                let itemId = ObjectIdentifier(item)
                if observedItems.contains(itemId) {
                    do {
                        item.removeObserver(self, forKeyPath: "status", context: nil)
                        ATLog(.debug, "🎵 [LCPPlayer] ✅ Removed observer during cleanup for: \(item.trackIdentifier ?? "unknown")")
                    } catch {
                        ATLog(.error, "🎵 [LCPPlayer] ❌ Failed to remove observer during cleanup: \(error)")
                    }
                }
            }
            observedItems.removeAll()
            ATLog(.debug, "🎵 [LCPPlayer] 🧹 Cleared all observer tracking")
        }
    }

    override var currentOffset: Double {
        guard let currentTrackPosition, let currentChapter else {
            return 0
        }

        let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
        // Enhanced logging for offset calculation debugging
        AudiobookLog.performance("currentOffset", value: offset, unit: "s")
        return offset
    }

    init(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) {
        self.decryptionDelegate = decryptor
        super.init(tableOfContents: tableOfContents)
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        super.init(tableOfContents: tableOfContents)
    }
    
    override func configurePlayer() {
        setupAudioSession()
        addPlayerObservers()
    }
    
    private func ensurePlayerQueueBuilt() {
        if !queueBuiltSuccessfully {
            ATLog(.debug, "🎵 [LCPPlayer] Building player queue on-demand for first playback")
            buildPlayerQueue()
        }
    }
    
    
    /// Handle AVPlayerItem status observations
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let playerItem = object as? AVPlayerItem {
            switch playerItem.status {
            case .readyToPlay:
                ATLog(.debug, "🎵 [LCPPlayer] ✅ AVPlayerItem ready: \(playerItem.trackIdentifier ?? "unknown")")
            case .failed:
                if let error = playerItem.error {
                    ATLog(.error, "🎵 [LCPPlayer] ❌ AVPlayerItem failed: \(playerItem.trackIdentifier ?? "unknown") - \(error)")
                } else {
                    ATLog(.error, "🎵 [LCPPlayer] ❌ AVPlayerItem failed: \(playerItem.trackIdentifier ?? "unknown") - unknown error")
                }
                
                // Check if this failure is causing item removal
                let currentQueueSize = avQueuePlayer.items().count
                ATLog(.error, "🎵 [LCPPlayer] Queue size after item failure: \(currentQueueSize)")
                
            case .unknown:
                ATLog(.debug, "🎵 [LCPPlayer] ⏳ AVPlayerItem status unknown: \(playerItem.trackIdentifier ?? "unknown")")
            @unknown default:
                break
            }
            } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
        }
    
    override public func play() {
        ATLog(.debug, "🎵 [LCPPlayer] play() called")
        super.play()
    }
    
    override public func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        ATLog(.debug, "🎵 [LCPPlayer] play(at position) called for track: \(position.track.title ?? "unknown"), timestamp: \(position.timestamp)")
        ATLog(.debug, "🎵 [LCPPlayer] 🔍 TRACK DETAILS: key='\(position.track.key)', index=\(position.track.index), href=\(position.track.urls?.first?.absoluteString ?? "nil")")
        ATLog(.debug, "🎵 [LCPPlayer] 🔍 TOC POSITION: Looking for track in TOC with \(tableOfContents.allTracks.count) total tracks")
        
        // Ensure queue is built before attempting playback
        ensurePlayerQueueBuilt()
        
        // Log current queue state before navigation
        let currentQueueSize = avQueuePlayer.items().count
        ATLog(.debug, "🎵 [LCPPlayer] 📊 PRE-NAVIGATION: Queue has \(currentQueueSize) items, actionAtItemEnd=\(avQueuePlayer.actionAtItemEnd.rawValue)")
        if currentQueueSize > 0 {
            let firstTrackId = avQueuePlayer.items().first?.trackIdentifier ?? "nil"
            let currentTrackId = avQueuePlayer.currentItem?.trackIdentifier ?? "nil"
            ATLog(.debug, "🎵 [LCPPlayer] 📊 First track: \(firstTrackId), Current: \(currentTrackId)")
        }
        
        // Start prioritized downloads when user actually tries to play
        //        startPrioritizedDownloadsIfNeeded()
        
        // Navigate first, then explicitly start playback
        performNavigationToPosition(position) { [weak self] error in
            guard let self = self else { return }
            
            // Log queue state after navigation
            let postNavQueueSize = self.avQueuePlayer.items().count
            ATLog(.debug, "🎵 [LCPPlayer] 📊 POST-NAVIGATION: Queue has \(postNavQueueSize) items, actionAtItemEnd=\(self.avQueuePlayer.actionAtItemEnd.rawValue)")
            if postNavQueueSize != currentQueueSize {
                ATLog(.error, "🎵 [LCPPlayer] ❌ QUEUE SIZE CHANGED during navigation: \(currentQueueSize) → \(postNavQueueSize)")
                if postNavQueueSize > 0 {
                    let newFirstTrackId = self.avQueuePlayer.items().first?.trackIdentifier ?? "nil"
                    ATLog(.error, "🎵 [LCPPlayer] New first track: \(newFirstTrackId)")
                }
            }
            
            if error == nil {
                self.avQueuePlayer.play()
                self.restorePlaybackRate()
                // CRITICAL: Notify UI that playback started
                self.playbackStatePublisher.send(.started(position))
            }
            completion?(error)
        }
    }
    
    /// Perform the actual navigation to a position with a stable queue - NO MORE REBUILDS
    private func performNavigationToPosition(_ position: TrackPosition, completion: ((Error?) -> Void)?) {
        ATLog(.debug, "🎵 [LCPPlayer] Performing STABLE navigation to track: \(position.track.key)")
        
        // CRITICAL: Ensure queue settings haven't been reset before navigation
        if avQueuePlayer.actionAtItemEnd != .none {
            ATLog(.error, "🎵 [LCPPlayer] ⚠️ actionAtItemEnd was \(avQueuePlayer.actionAtItemEnd.rawValue)! Re-enforcing settings...")
            enforceStableQueueSettings()
        }
        
        isNavigating = true
        
        // With stable queue, we navigate first, then handle resources
        navigateDirectlyToPosition(position) { [weak self] success in
            guard let self = self else { return }
            
            if success {
                // Now handle track-specific resources if needed
                if let lcpTrack = position.track as? LCPTrack {
                    if !lcpTrack.hasLocalFiles() && lcpTrack.streamingResource == nil {
                        // Load streaming resource in background while playing placeholder
                        self.loadStreamingResourceForTrack(position.track)
                    }
                }
                
                self.isNavigating = false
                completion?(nil)
            } else {
                self.isNavigating = false
                completion?(NSError(domain: "LCPPlayerError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Navigation failed"]))
            }
        }
    }
    
    /// Navigate directly within the stable queue without any rebuilds
    private func navigateDirectlyToPosition(_ position: TrackPosition, completion: @escaping (Bool) -> Void) {
        // FIRST: Check and restore queue integrity before navigation
        monitorQueueIntegrity()
        
        var queueItems = avQueuePlayer.items()
        
        ATLog(.debug, "🎵 [LCPPlayer] Navigating to track: '\(position.track.key)' at timestamp: \(position.timestamp)s in queue of \(queueItems.count) items")
        ATLog(.debug, "🎵 [LCPPlayer] Track title: '\(position.track.title ?? "nil")', index: \(position.track.index)")
        
        // Find target item in our stable queue
        var targetIndex: Int
        if let foundIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
            targetIndex = foundIndex
            ATLog(.debug, "🎵 [LCPPlayer] ✅ Found track '\(position.track.key)' at queue index \(foundIndex)")
        } else {
            ATLog(.debug, "🎵 [LCPPlayer] ❌ Track not found in current queue: \(position.track.key)")
            ATLog(.debug, "🎵 [LCPPlayer] Available track keys: \(queueItems.compactMap { $0.trackIdentifier })")
            
            // Fall back to full rebuild only if efficient restore fails
            ATLog(.debug, "🎵 [LCPPlayer] Efficient restore failed, falling back to full rebuild")
            self.rebuildQueueFromTargetTrack(position.track, timestamp: position.timestamp, shouldPlay: false, completion: completion)
            return
        }
        
        let currentIndex = queueItems.firstIndex(where: { $0 == avQueuePlayer.currentItem }) ?? 0
        ATLog(.debug, "🎵 [LCPPlayer] Stable navigation: \(currentIndex) → \(targetIndex)")
        
        let shouldPlay = avQueuePlayer.rate > 0
        avQueuePlayer.pause()
        
        // Use AVQueuePlayer's efficient navigation within the existing queue
        if targetIndex == currentIndex {
            // Same track, just seek
            let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            ATLog(.debug, "🎵 [LCPPlayer] Same track - seeking to \(position.timestamp)s")
            avQueuePlayer.seek(to: seekTime) { success in
                if shouldPlay {
                    self.avQueuePlayer.play()
                    self.restorePlaybackRate()
                    // Notify UI that playback resumed after seek
                    self.playbackStatePublisher.send(.started(position))
                }
                completion(success)
            }
        } else if targetIndex > currentIndex {
            // Forward navigation: Use AVQueuePlayer's natural advance
            ATLog(.debug, "🎵 [LCPPlayer] Forward navigation: advancing \(targetIndex - currentIndex) items")
            for _ in currentIndex..<targetIndex {
                avQueuePlayer.advanceToNextItem()
            }
            let seekTime = CMTime(seconds: position.timestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            avQueuePlayer.seek(to: seekTime) { success in
                if shouldPlay {
                    self.avQueuePlayer.play()
                    self.restorePlaybackRate()
                    self.playbackStatePublisher.send(.started(position))
                }
                completion(success)
            }
        } else {
            // Backward navigation: Only rebuild if absolutely necessary
            ATLog(.debug, "🎵 [LCPPlayer] Backward navigation detected - using targeted rebuild")
            self.rebuildQueueFromTargetTrack(position.track, timestamp: position.timestamp, shouldPlay: shouldPlay, completion: completion)
        }
    }
    
    /// Smart queue rebuild starting from a specific track (for backward navigation only)
    private func rebuildQueueFromTargetTrack(_ targetTrack: any Track, timestamp: TimeInterval, shouldPlay: Bool, completion: @escaping (Bool) -> Void) {
        ATLog(.debug, "🎵 [LCPPlayer] Smart rebuild starting from track: \(targetTrack.key)")
        
        // Clear any stale navigation state that might interfere
        isNavigating = true
        
        let allTracks = tableOfContents.allTracks
        guard let targetIndex = allTracks.firstIndex(where: { $0.key == targetTrack.key }) else {
            ATLog(.error, "🎵 [LCPPlayer] Target track not found in table of contents")
            completion(false)
            return
        }
        
        // BUILD COMPLETE QUEUE: All tracks to preserve navigation integrity
        let newItems = buildPlayerItems(fromTracks: allTracks)
        
        ATLog(.debug, "🎵 [LCPPlayer] Building complete queue (\(allTracks.count) tracks) for target track '\(targetTrack.key)'")
        
        // Clear queue and rebuild starting from target track to maintain navigation
        let itemsBeforeRemoval = avQueuePlayer.items().count
        avQueuePlayer.removeAllItems()
        let itemsAfterRemoval = avQueuePlayer.items().count
        ATLog(.debug, "🎵 [LCPPlayer] Queue cleared: \(itemsBeforeRemoval) -> \(itemsAfterRemoval) items")
        
        // Reorder items to start from target track, then continue with all tracks
        let targetItemIndex = targetIndex
        let reorderedItems = Array(newItems[targetItemIndex...]) + Array(newItems[0..<targetItemIndex])
        
        // Insert all items in the reordered sequence
        var insertedCount = 0
        for (index, item) in reorderedItems.enumerated() {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
                insertedCount += 1
            } else {
                ATLog(.error, "🎵 [LCPPlayer] ❌ CRITICAL: Cannot insert item \(index) with trackIdentifier: \(item.trackIdentifier ?? "nil") - AVQueuePlayer rejected it")
                // Try to understand why insertion failed
                if let trackId = item.trackIdentifier {
                    let isAlreadyInQueue = avQueuePlayer.items().contains { $0.trackIdentifier == trackId }
                    ATLog(.error, "🎵 [LCPPlayer] Item already in queue: \(isAlreadyInQueue)")
                }
            }
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Successfully inserted \(insertedCount)/\(reorderedItems.count) items into queue")
        
        // Update our tracking with items that were ACTUALLY inserted into the queue
        trackToItemMapping.removeAll()
        let actuallyInsertedItems = avQueuePlayer.items()
        for item in actuallyInsertedItems {
            if let trackKey = item.trackIdentifier {
                if trackToItemMapping[trackKey] == nil {
                    trackToItemMapping[trackKey] = []
                }
                trackToItemMapping[trackKey]?.append(item)
            }
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Rebuilt queue starting from target track '\(targetTrack.key)' (originally at index \(targetIndex))")
        
        // DEBUG: Verify queue contents
        let finalQueueItems = avQueuePlayer.items()
        ATLog(.debug, "🎵 [LCPPlayer] Queue after rebuild: \(finalQueueItems.count) items")
        ATLog(.debug, "🎵 [LCPPlayer] First 5 items: \(finalQueueItems.prefix(5).compactMap { $0.trackIdentifier })")
        ATLog(.debug, "🎵 [LCPPlayer] Target track '\(targetTrack.key)' in queue: \(finalQueueItems.contains { $0.trackIdentifier == targetTrack.key })")
        
        // Seek to the requested timestamp (avoid exact end which can trigger immediate completion)
        let safeTimestamp: TimeInterval
        if timestamp >= targetTrack.duration {
            safeTimestamp = max(0, targetTrack.duration - 0.5)
        } else if targetTrack.index == (tableOfContents.allTracks.count - 1) && (targetTrack.duration - timestamp) < 0.25 {
            safeTimestamp = max(0, targetTrack.duration - 0.5)
        } else {
            safeTimestamp = max(0, timestamp)
        }
        let seekTime = CMTime(seconds: safeTimestamp, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: seekTime) { success in
            // Clear navigation state
            self.isNavigating = false
            
            if success && shouldPlay {
                self.avQueuePlayer.play()
                self.restorePlaybackRate()
                // Notify UI that playback started after queue rebuild
                let trackPosition = TrackPosition(track: targetTrack, timestamp: safeTimestamp, tracks: self.tableOfContents.tracks)
                self.playbackStatePublisher.send(.started(trackPosition))
            }
            
            completion(success)
        }
    }
    
    /// OVERRIDE: Fix the broken parent navigation that causes constant rebuilds
    
    
    /// Maintain a complete mapping of all tracks for reliable backward navigation
    private func preserveQueueItems() {
        // Store the complete original queue for restoration when items get removed
        let allItems = avQueuePlayer.items()
        for item in allItems {
            if let trackKey = item.trackIdentifier {
                if trackToItemMapping[trackKey] == nil {
                    trackToItemMapping[trackKey] = []
                }
                trackToItemMapping[trackKey]?.append(item)
            }
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Preserved mapping for \(trackToItemMapping.keys.count) tracks")
        
        // Disable complex monitoring - let AVQueuePlayer behave naturally
        // startQueueMonitoring()
    }
    
    /// Actively monitor queue integrity and restore missing items
    private func startQueueMonitoring() {
        // Invalidate any existing timer
        queueMonitoringTimer?.invalidate()
        
        queueMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, self.queueBuiltSuccessfully else {
                timer.invalidate()
                return
            }
            
            let currentCount = self.avQueuePlayer.items().count
            ATLog(.debug, "🎵 [LCPPlayer] Queue monitoring: \(currentCount) items")
            
            // Detect silent item removal (only restore if significant loss)
            let expectedCount = self.tableOfContents.allTracks.count
            let significantLoss = expectedCount - currentCount >= 5 // At least 5 items lost
            let timeSinceLastRestore = Date().timeIntervalSince(self.lastQueueRestoreTime)
            let cooldownPeriod: TimeInterval = 10.0 // Wait 10 seconds between restorations
            
            if currentCount < expectedCount && significantLoss && !self.isNavigating && timeSinceLastRestore > cooldownPeriod {
                let firstTrack = self.avQueuePlayer.items().first?.trackIdentifier ?? "nil"
                let currentTrack = self.avQueuePlayer.currentItem?.trackIdentifier ?? "nil"
                
                ATLog(.error, "🎵 [LCPPlayer] 🚨 SILENT ITEM REMOVAL DETECTED! Queue: \(currentCount)/\(expectedCount) items")
                ATLog(.error, "🎵 [LCPPlayer] First: \(firstTrack), Current: \(currentTrack)")
                ATLog(.error, "🎵 [LCPPlayer] actionAtItemEnd: \(self.avQueuePlayer.actionAtItemEnd.rawValue)")
                
                // Log which tracks are missing (first few for diagnostics)
                let presentTrackIds = self.avQueuePlayer.items().compactMap { $0.trackIdentifier }
                let allTrackIds = self.tableOfContents.allTracks.map { $0.key }
                let missingTrackIds = allTrackIds.filter { !presentTrackIds.contains($0) }
                
                ATLog(.error, "🎵 [LCPPlayer] Missing \(missingTrackIds.count) tracks:")
                for (index, trackId) in missingTrackIds.prefix(5).enumerated() {
                    ATLog(.error, "🎵 [LCPPlayer] Missing[\(index)]: \(trackId.prefix(8))...")
                }
                
                // AUTO-RESTORE: Proactively rebuild to full count
                ATLog(.debug, "🎵 [LCPPlayer] 🔧 AUTO-RESTORING queue to full \(expectedCount) items...")
                self.lastQueueRestoreTime = Date()
                self.proactivelyRestoreQueue()
            }
        }
    }
    
    /// Proactively restore missing queue items without disrupting current playback
    /// PERFORMANCE FIX: Optimized to reduce UI blocking during debug
    private func proactivelyRestoreQueue() {
        // Defer heavy queue operations to background thread to prevent UI lag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performQueueRestore()
        }
    }
    
    /// Perform the actual queue restoration on background thread
    private func performQueueRestore() {
        let currentItems = avQueuePlayer.items()
        let allTracks = tableOfContents.allTracks
        
        // Find missing tracks from the beginning
        var missingTrackKeys: [String] = []
        for track in allTracks {
            if !currentItems.contains(where: { $0.trackIdentifier == track.key }) {
                missingTrackKeys.append(track.key)
            }
        }
        
        if missingTrackKeys.isEmpty {
            return // Nothing to restore
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Restoring \(missingTrackKeys.count) missing tracks: \(missingTrackKeys.prefix(5))")
        
        // BETTER APPROACH: Rebuild the entire queue in the correct order
        // Save current playback state
        let wasPlaying = avQueuePlayer.rate > 0
        let currentTime = avQueuePlayer.currentTime()
        let currentTrackKey = avQueuePlayer.currentItem?.trackIdentifier
        
        // Clear queue and rebuild with ALL tracks in correct order
        avQueuePlayer.removeAllItems()
        trackToItemMapping.removeAll()
        
        // Build complete queue in correct order
        let allPlayerItems = buildPlayerItems(fromTracks: allTracks)
        ATLog(.debug, "🎵 [LCPPlayer] proactivelyRestoreQueue: Prepared \(allPlayerItems.count) items for full queue rebuild.")
        
        // Insert all items in order
        var insertedCount = 0
        for item in allPlayerItems {
            if let trackKey = item.trackIdentifier {
                if trackToItemMapping[trackKey] == nil {
                    trackToItemMapping[trackKey] = []
                }
                trackToItemMapping[trackKey]?.append(item)
            }
            
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
                insertedCount += 1
            } else {
                ATLog(.error, "🎵 [LCPPlayer] proactivelyRestoreQueue: ❌ Failed to insert item for track: \(item.trackIdentifier ?? "nil")")
            }
        }
        ATLog(.debug, "🎵 [LCPPlayer] proactivelyRestoreQueue: Successfully inserted \(insertedCount) items into AVQueuePlayer.")
        
        // Restore playback position if we had one
        if let currentTrackKey = currentTrackKey,
           let targetItem = avQueuePlayer.items().first(where: { $0.trackIdentifier == currentTrackKey }) {
            
            // Advance to the correct track
            while avQueuePlayer.currentItem != targetItem && avQueuePlayer.currentItem != nil {
                avQueuePlayer.advanceToNextItem()
            }
            
            // Restore time position
            if currentTime.isValid && currentTime.seconds > 0.01 {
                avQueuePlayer.seek(to: currentTime)
            }
            
            // Restore playback state
            if wasPlaying {
                avQueuePlayer.play()
            }
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Queue restoration complete - now has \(avQueuePlayer.items().count) items in correct order")
    }
    
    /// Monitor queue state and restore missing items when needed for backward navigation
    private func monitorQueueIntegrity() {
        // This will be called before any navigation to ensure queue completeness
        let currentItems = avQueuePlayer.items()
        let allTracks = tableOfContents.allTracks
        
        // Only restore if the queue is completely empty
        if currentItems.isEmpty {
            ATLog(.debug, "🎵 [LCPPlayer] Queue empty, restoring")
            proactivelyRestoreQueue()
            return
        }
        
        // For normal playback, let AVQueuePlayer behave naturally
        // Only check if we have at least a few items for basic navigation
        if currentItems.count >= 3 {
            ATLog(.debug, "🎵 [LCPPlayer] Queue integrity sufficient for navigation (\(currentItems.count) items)")
            return
        }
        
        // Only restore if we have very few items left AND need backward navigation
        let missingEarlierTracks = currentItems.first?.trackIdentifier != allTracks.first?.key
        
        if missingEarlierTracks && currentItems.count < 3 {
            ATLog(.debug, "🎵 [LCPPlayer] Minimal queue for backward navigation (\(currentItems.count) items) - restoring")
            
            // Find current position in original track list
            if let currentItem = avQueuePlayer.currentItem,
               let currentTrackKey = currentItem.trackIdentifier,
               let currentTrackIndex = allTracks.firstIndex(where: { $0.key == currentTrackKey }) {
                
                ATLog(.debug, "🎵 [LCPPlayer] Restoring missing tracks before index \(currentTrackIndex)")
                restoreQueueFromPosition(currentTrackIndex)
            }
        } else {
            ATLog(.debug, "🎵 [LCPPlayer] Queue integrity sufficient for navigation (\(currentItems.count) items)")
        }
    }
    
    /// Restore queue from a specific track position to ensure backward navigation capability
    private func restoreQueueFromPosition(_ startIndex: Int) {
        let allTracks = tableOfContents.allTracks
        
        // Get tracks from start of book to current position (for backward navigation)
        let tracksForBackward = Array(allTracks[0..<startIndex])
        let tracksFromCurrent = Array(allTracks[startIndex...])
        
        // Build items for missing tracks and insert them at the beginning
        let backwardItems = buildPlayerItems(fromTracks: tracksForBackward)
        
        // Insert backward navigation items at the front of the queue
        for item in backwardItems.reversed() {
            if let currentFirst = avQueuePlayer.items().first {
                if avQueuePlayer.canInsert(item, after: nil) {
                    avQueuePlayer.insert(item, after: nil)
                    addEndObserver(for: item)
                }
            }
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Queue restored: added \(backwardItems.count) items for backward navigation")
    }
    
    
    /// Ensure streaming resources are loaded for tracks around the current position (on-demand)
    private func ensureTracksLoadedAroundPosition(_ position: TrackPosition) {
        let allTracks = tableOfContents.allTracks
        guard let currentIndex = allTracks.firstIndex(where: { $0.key == position.track.key }) else { return }
        
        // Load streaming resources for current track + next track for smooth playback
        let currentTrack = allTracks[currentIndex]
        
        // Always load streaming resource for current track if needed
        if let lcpTrack = currentTrack as? LCPTrack,
           !lcpTrack.hasLocalFiles(),
           lcpTrack.streamingResource == nil {
            ATLog(.debug, "🎵 [LCPPlayer] Loading streaming resource for current track: \(currentTrack.key)")
            loadStreamingResourceForTrack(currentTrack)
        }
        
        // Optionally preload next track's streaming resource
        if currentIndex + 1 < allTracks.count {
            let nextTrack = allTracks[currentIndex + 1]
            if let lcpTrack = nextTrack as? LCPTrack,
               !lcpTrack.hasLocalFiles(),
               lcpTrack.streamingResource == nil {
                ATLog(.debug, "🎵 [LCPPlayer] Preloading streaming resource for next track: \(nextTrack.key)")
                loadStreamingResourceForTrack(nextTrack)
            }
        }
    }
    
    override public func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition ?? lastKnownPosition else {
            completion?(nil)
            return
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] skipPlayhead called with timeInterval: \(timeInterval)s from current position")
        
        let newPosition = currentTrackPosition + timeInterval
        
        ATLog(.debug, "🎵 [LCPPlayer] Skip calculated new position: track=\(newPosition.track.key), timestamp=\(newPosition.timestamp)")
        
        // For skips, we should NOT rebuild the queue every time
        // Just ensure the target track resources are available and seek directly
        
        if let lcpTrack = newPosition.track as? LCPTrack {
            // Preload streaming resource if needed, but don't wait for it
            if !lcpTrack.hasLocalFiles() && lcpTrack.streamingResource == nil {
                ATLog(.debug, "🎵 [LCPPlayer] Skip target track needs streaming resource, loading in background...")
                loadStreamingResourceForTrack(newPosition.track)
            }
        }
        
        // Seek directly without queue rebuilding - AVQueuePlayer can handle seeks to any track in queue
        performSuperSeek(to: newPosition, completion: completion)
    }
    
    private func performSuperPlay(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        super.play(at: position, completion: completion)
    }
    
    private func performSuperSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        ATLog(.debug, "🎵 [LCPPlayer] performSuperSeek to track: \(position.track.key), timestamp: \(position.timestamp)")
        
        // Validate the position before seeking
        guard position.timestamp >= 0 && position.timestamp <= position.track.duration else {
            ATLog(.error, "🎵 [LCPPlayer] Invalid seek position: timestamp=\(position.timestamp), track duration=\(position.track.duration)")
            completion?(nil)
            return
        }
        
        super.seekTo(position: position, completion: completion)
    }
    
    private func decryptTrackIfNeeded(track: any Track, completion: @escaping (Bool) -> Void) {
        guard let task = track.downloadTask as? LCPDownloadTask, let decryptedUrls = task.decryptedUrls else {
            completion(false)
            return
        }
        
        // Check if local files exist
        let missing = decryptedUrls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if missing.isEmpty {
            completion(true)
            return
        }
        
        // For LCP tracks, always try to decrypt locally
        // Streaming is handled separately through LCPTrack.streamingResource
        performLocalDecrypt(missing, using: task, completion: completion)
    }
    
    /// Helper to decrypt missing URLs
    private func performLocalDecrypt(
        _ missing: [URL],
        using task: LCPDownloadTask,
        completion: @escaping (Bool) -> Void
    ) {
        decryptionQueue.async(execute: { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            guard let decryptedUrls = task.decryptedUrls else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            let group = DispatchGroup()
            var success = true
            
            for (idx, dest) in decryptedUrls.enumerated() where missing.contains(dest) {
                group.enter()
                //                self.decryptionLock.lock()
                self.decryptionDelegate?.decrypt(url: task.urls[idx], to: dest) { err in
                    if err != nil { success = false }
                    //                    self.decryptionLock.unlock()
                    group.leave()
                }
            }
            
            group.notify(queue: DispatchQueue.main) {
                ATLog(.debug, "🎵 [LCPPlayer] Local decryption completed for \(missing.count) files, success: \(success)")
                if success {
                    // Proactively update queue when files become available locally (with smart throttling)
                    self.refreshQueueAfterDecryption()
                }
                completion(success)
            }
        })
    }
    
    /// Smart update: Replace specific items when decryption completes, no full rebuilds
    private func refreshQueueAfterDecryption() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isLoaded, self.queueBuiltSuccessfully, !self.isUpdatingCurrentItem else { return }
            
            ATLog(.debug, "🎵 [LCPPlayer] Smart queue update after decryption - no rebuilds needed")
            
            // The beauty of stable queues: decrypted files will be picked up automatically
            // when AVPlayer tries to play placeholder items, or we can proactively update
            // the current item if needed without touching the entire queue
            
            // Only action needed: If current item is using placeholder, recreate just that item
            if let currentItem = self.avQueuePlayer.currentItem,
               let trackKey = currentItem.trackIdentifier,
               let track = self.tableOfContents.track(forKey: trackKey),
               let lcpTrack = track as? LCPTrack,
               lcpTrack.hasLocalFiles() {
                self.updateCurrentItemIfNeeded(for: track)
            }
        }
    }
    
    /// Update only the current item when better resources become available
    private func updateCurrentItemIfNeeded(for track: any Track) {
        guard let currentItem = avQueuePlayer.currentItem,
              currentItem.trackIdentifier == track.key,
              !isUpdatingCurrentItem else { return }
        
        // Prevent recursive updates
        isUpdatingCurrentItem = true
        defer { isUpdatingCurrentItem = false }
        
        ATLog(.debug, "🎵 [LCPPlayer] Updating current item for improved playback: \(track.key)")
        
        // Build new items for this track
        let newItems = buildPlayerItems(fromTracks: [track])
        guard let newItem = newItems.first else { return }
        
        // Get current playback time
        let currentTime = currentItem.currentTime()
        
        // Remove observer from old item BEFORE replacement to prevent crash
        safeRemoveObserver(from: currentItem)
        
        // Insert new item after current and seek to same position
        if avQueuePlayer.canInsert(newItem, after: currentItem) {
            avQueuePlayer.insert(newItem, after: currentItem)
            addEndObserver(for: newItem)
            
            // Advance to the new item and seek to preserve position
            avQueuePlayer.advanceToNextItem()
            if currentTime.isValid && currentTime.seconds > 0.01 {
                avQueuePlayer.seek(to: currentTime)
            }
            
            ATLog(.debug, "🎵 [LCPPlayer] ✅ Current item updated seamlessly")
        }
    }
    
    /// Override resetPlayerQueue to handle our observer tracking
    override public func resetPlayerQueue() {
        // Remove observers before removing items
        safeRemoveAllObservers()
        super.resetPlayerQueue()
    }
    
    
    /// Build the queue once with a stable foundation - no more constant rebuilds
    /// PERFORMANCE FIX: Optimized to prevent UI blocking during queue building
    override public func buildPlayerQueue() {
        ATLog(.info, "🎵 [LCPPlayer] Building stable player queue once")
        
        // Only build the queue once successfully
        if queueBuiltSuccessfully {
            ATLog(.info, "🎵 [LCPPlayer] Queue already built successfully, skipping rebuild")
            return
        }
        
        // PERFORMANCE FIX: Build queue on background thread for large audiobooks
        let allTracks = tableOfContents.allTracks
        if allTracks.count > 50 { // Large audiobook threshold
            ATLog(.info, "🎵 [LCPPlayer] Large audiobook (\(allTracks.count) tracks) - building queue on background thread")
            buildLargeAudiobookQueue(tracks: allTracks)
            return
        }
        
        // Small audiobooks can be built on main thread
        buildSmallAudiobookQueue(tracks: allTracks)
    }
    
    /// Build queue for large audiobooks (>= 50 tracks) on background thread
    private func buildLargeAudiobookQueue(tracks: [any Track]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let playerItems = self.buildPlayerItems(fromTracks: tracks)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.isNavigating = true
                self.resetPlayerQueue()
                self.trackToItemMapping.removeAll()
                
                ATLog(.info, "🎵 [LCPPlayer] Built \(playerItems.count) player items from \(tracks.count) tracks on background thread")
                
                if playerItems.isEmpty {
                    ATLog(.error, "🎵 [LCPPlayer] ❌ No player items created!")
                    self.isLoaded = false
                    self.isNavigating = false
                    return
                }
                
                // Insert items in batches to prevent UI blocking
                self.insertPlayerItemsInBatches(playerItems)
            }
        }
    }
    
    /// Insert player items in batches to prevent UI blocking
    private func insertPlayerItemsInBatches(_ playerItems: [AVPlayerItem]) {
        let batchSize = 10 // Insert 10 items at a time
        var currentIndex = 0
        
        func insertNextBatch() {
            let endIndex = min(currentIndex + batchSize, playerItems.count)
            let batch = Array(playerItems[currentIndex..<endIndex])
            
            for (index, item) in batch.enumerated() {
                let globalIndex = currentIndex + index
                if avQueuePlayer.canInsert(item, after: nil) {
                    avQueuePlayer.insert(item, after: nil)
                    addEndObserver(for: item)
                } else {
                    ATLog(.error, "🎵 [LCPPlayer] ❌ Cannot insert item \(globalIndex) during batch insert")
                }
            }
            
            currentIndex = endIndex
            
            if currentIndex < playerItems.count {
                // Schedule next batch on next run loop to prevent blocking
                DispatchQueue.main.async {
                    insertNextBatch()
                }
            } else {
                // Completed inserting all items
                self.finishQueueBuild()
            }
        }
        
        insertNextBatch()
    }
    
    /// Finish queue building process
    private func finishQueueBuild() {
        // Build mapping based on items that were ACTUALLY inserted
        let insertedItems = avQueuePlayer.items()
        for item in insertedItems {
            if let trackId = item.trackIdentifier {
                trackToItemMapping[trackId] = [item]
            }
        }
        
        ATLog(.info, "🎵 [LCPPlayer] ✅ Queue built successfully with \(insertedItems.count) items, mapping: \(trackToItemMapping.count)")
        
        isLoaded = true
        queueBuiltSuccessfully = true
        isNavigating = false
        
        // delegate?.playerDidUpdatePlaybackState(self) // Delegate not available in this context
    }
    
    /// Build queue for small audiobooks (< 50 tracks) on main thread
    private func buildSmallAudiobookQueue(tracks: [any Track]) {
        isNavigating = true
        resetPlayerQueue()
        trackToItemMapping.removeAll()
        
        let playerItems = buildPlayerItems(fromTracks: tracks)
        
        ATLog(.info, "🎵 [LCPPlayer] Built \(playerItems.count) player items from \(tracks.count) tracks")
        
        if playerItems.isEmpty {
            ATLog(.error, "🎵 [LCPPlayer] ❌ No player items created!")
            isLoaded = false
            isNavigating = false
            return
        }
        
        // Insert items first, then build mapping based on what was actually inserted
        var insertedCount = 0
        for (index, item) in playerItems.enumerated() {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
                insertedCount += 1
            } else {
                ATLog(.error, "🎵 [LCPPlayer] ❌ CRITICAL: Cannot insert item \(index) with trackIdentifier: \(item.trackIdentifier ?? "nil") during initial queue build - AVQueuePlayer rejected it")
                // Try to understand why insertion failed
                if let trackId = item.trackIdentifier {
                    let isAlreadyInQueue = avQueuePlayer.items().contains { $0.trackIdentifier == trackId }
                    ATLog(.error, "🎵 [LCPPlayer] Item already in queue: \(isAlreadyInQueue)")
                    ATLog(.error, "🎵 [LCPPlayer] Current queue size: \(avQueuePlayer.items().count)")
                }
            }
        }
        
        // Build mapping based on items that were ACTUALLY inserted
        trackToItemMapping.removeAll()
        let actuallyInsertedItems = avQueuePlayer.items()
        for item in actuallyInsertedItems {
            if let trackKey = item.trackIdentifier {
                if trackToItemMapping[trackKey] == nil {
                    trackToItemMapping[trackKey] = []
                }
                trackToItemMapping[trackKey]?.append(item)
            }
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Initial queue build: Successfully inserted \(insertedCount)/\(playerItems.count) items")
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        
        // CRITICAL FIX: Prevent AVQueuePlayer from automatically removing played items
        // This preserves our stable queue for backward navigation
        enforceStableQueueSettings()
        
        self.preserveQueueItems()
        
        isLoaded = true
        queueBuiltSuccessfully = true
        isNavigating = false
        
        ATLog(.debug, "🎵 [LCPPlayer] ✅ Stable queue built successfully with \(insertedCount) items - auto-removal disabled")
    }
    
    // Ensure end-of-item notifications don't interfere during navigation/rebuilds
    @objc override func playerItemDidReachEnd(_ notification: Notification) {
        if isNavigating {
            ATLog(.debug, "🎵 [LCPPlayer] Ignoring end-of-item during navigation")
            return
        }
        super.playerItemDidReachEnd(notification)
    }
    
    /// Enforce queue settings to prevent automatic item removal
    private func enforceStableQueueSettings() {
        avQueuePlayer.actionAtItemEnd = .none  // Prevent automatic removal of played items
        ATLog(.debug, "🎵 [LCPPlayer] ✅ Set actionAtItemEnd = .none to prevent automatic item removal")
        
        // Verify the setting stuck
        ATLog(.debug, "🎵 [LCPPlayer] 🔍 actionAtItemEnd verification: \(avQueuePlayer.actionAtItemEnd.rawValue) (0=advance, 1=pause, 2=none)")
        
        
        
        // Double-check after a brief delay to catch any async resets
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if self.avQueuePlayer.actionAtItemEnd != .none {
                ATLog(.error, "🎵 [LCPPlayer] ❌ actionAtItemEnd was RESET! Current value: \(self.avQueuePlayer.actionAtItemEnd.rawValue)")
                self.avQueuePlayer.actionAtItemEnd = .none
                ATLog(.debug, "🎵 [LCPPlayer] 🔧 Re-applied actionAtItemEnd = .none")
            }
        }
    }
    
    
    
    /// Alternative approach: Override AVQueuePlayer to completely disable automatic advancement
    private func disableAutomaticAdvancement() {
        // EXPERIMENTAL: Try setting actionAtItemEnd to .pause and manually controlling advancement
        avQueuePlayer.actionAtItemEnd = .pause
        ATLog(.debug, "🎵 [LCPPlayer] 🔧 EXPERIMENTAL: Set actionAtItemEnd = .pause to manually control advancement")
    }
    
    /// Ultra-simple approach: use custom URLs and let resource loader handle everything
    override public func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
        var items = [AVPlayerItem]()
        
        ATLog(.debug, "🎵 [LCPPlayer] buildPlayerItems called for \(tracks.count) tracks")
        
        for (index, track) in tracks.enumerated() {
            let playerItem = createPlayerItem(for: track, index: index)
                    items.append(playerItem)
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] buildPlayerItems: Created \(items.count) items from \(tracks.count) tracks")
        return items
    }
    
    /// Create player item using simple priority approach (working solution)
    private func createPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
        ATLog(.debug, "🎵 [LCPPlayer] Creating item for track: \(track.key)")
        
        // 1. Try local file first (best option)
        if let localUrl = getLocalFileUrl(for: track) {
            ATLog(.debug, "🎵 [LCPPlayer] ✅ Using LOCAL file for track: \(track.key)")
            let item = AVPlayerItem(url: localUrl)
            item.audioTimePitchAlgorithm = .timeDomain
            item.trackIdentifier = track.key
            safeAddObserver(to: item)
            return item
        }
        
        // 2. Try streaming URL second (immediate playback)
        if let lcpTrack = track as? LCPTrack, let streamingUrl = lcpTrack.streamingResource {
            ATLog(.debug, "🎵 [LCPPlayer] 🌊 Using STREAMING for track: \(track.key)")
            let item = AVPlayerItem(url: streamingUrl)
            item.audioTimePitchAlgorithm = .timeDomain
            item.trackIdentifier = track.key
            return item
        }
        
        // 3. Use original URL as placeholder and start loading resources
        ATLog(.debug, "🎵 [LCPPlayer] 📄 Using PLACEHOLDER for track: \(track.key) - loading resources...")
        
        startResourceLoading(for: track)
        
        let placeholderUrl = track.urls?.first ?? URL(string: "https://example.com/placeholder.mp3")!
        let item = AVPlayerItem(url: placeholderUrl)
        item.audioTimePitchAlgorithm = .timeDomain
        item.trackIdentifier = track.key
        safeAddObserver(to: item)
        return item
    }
    
    /// Get the publication from the decryption delegate
    private func getPublication() -> Publication? {
        // For now, we'll need to implement this synchronously or cache it
        // The resource loader needs immediate access to the publication
        return nil // Will be set up when we have the publication cached
    }
    
    /// Set up resource loaders once we have a publication
    private func setupResourceLoaders(with publication: Publication) {
        // Store publication for use in resource loaders
        // We'll need to implement this when setting up the player
    }
    
    /// Get local file URL if available and valid
    private func getLocalFileUrl(for track: any Track) -> URL? {
        guard let lcpTask = track.downloadTask as? LCPDownloadTask,
              let decryptedUrls = lcpTask.decryptedUrls else {
            return nil
        }
        
        // Find first existing file with content
        for url in decryptedUrls {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
                    if fileSize > 0 {
                        return url
                    }
                } catch {
                    ATLog(.error, "🎵 [LCPPlayer] Failed to check file: \(url.path)")
                }
            }
        }
        return nil
    }
    
    /// Start resource loading for better future performance
    private func startResourceLoading(for track: any Track) {
        // Start background decryption if needed
            if let lcpTask = track.downloadTask as? LCPDownloadTask,
               let decryptedUrls = lcpTask.decryptedUrls {
            let missingFiles = decryptedUrls.filter { !FileManager.default.fileExists(atPath: $0.path) }
            if !missingFiles.isEmpty {
                performLocalDecrypt(missingFiles, using: lcpTask) { _ in }
            }
        }
    }
    
    //    /// Override play methods to start downloads only when user actually wants to play
    //    override func play() {
    //        // Start prioritized downloads when user actually tries to play
    //        startPrioritizedDownloadsIfNeeded()
    //        super.play()
    //    }
    //
    
    
    private func startPrioritizedDownloadsIfNeeded() {
        guard !hasStartedPrioritizedDownloads else {
            ATLog(.debug, "🎵 [LCPPlayer] Prioritized downloads already started, skipping")
            return
        }
        
        hasStartedPrioritizedDownloads = true
        let allTracks = tableOfContents.allTracks
        ATLog(.debug, "🎵 [LCPPlayer] Starting prioritized downloads on first play")
        prioritizeStreamingDownloads(for: allTracks)
    }
    
    /// Prioritize streaming downloads: current track first, then surrounding tracks
    private func prioritizeStreamingDownloads(for tracks: [any Track]) {
        guard let currentTrack = currentTrackPosition?.track else {
            startDownloadsForInitialTracks(tracks)
            return
        }
        
        let currentIndex = currentTrack.index
        let maxTracksToDownload = 3
        var prioritizedIndices: [Int] = [currentIndex]
        
        for offset in 1...maxTracksToDownload {
            if currentIndex + offset < tracks.count {
                prioritizedIndices.append(currentIndex + offset)
            }
            if currentIndex - offset >= 0 {
                prioritizedIndices.append(currentIndex - offset)
            }
        }
        
        for index in prioritizedIndices {
            guard index < tracks.count,
                  let lcpTask = tracks[index].downloadTask as? LCPDownloadTask else {
                continue
            }
            
            ATLog(.debug, "🎵 [LCPPlayer] Track \(index) will be handled by traditional LCP download system: \(tracks[index].key)")
        }
    }
    
    /// Traditional LCP downloads are handled automatically by the existing download system
    private func startDownloadsForInitialTracks(_ tracks: [any Track]) {
        let maxInitialDownloads = 2
        for (index, track) in tracks.prefix(maxInitialDownloads).enumerated() {
            ATLog(.debug, "🎵 [LCPPlayer] Track \(index) will use traditional LCP download system: \(track.key)")
        }
    }
    
    private func updateQueueForTrack(_ track: any Track, completion: @escaping () -> Void) {
        let currentItems = avQueuePlayer.items()
        let trackInQueue = currentItems.contains { $0.trackIdentifier == track.key }
        
        if !trackInQueue {
            ATLog(.debug, "🎵 [LCPPlayer] Track \(track.key) not in queue, needs updating")
        } else {
            if let lcpTrack = track as? LCPTrack,
               !lcpTrack.hasLocalFiles(),
               lcpTrack.streamingResource != nil {
                ATLog(.debug, "🎵 [LCPPlayer] Track \(track.key) in queue but has new streaming resource, updating")
            } else {
                ATLog(.debug, "🎵 [LCPPlayer] Track \(track.key) already properly loaded in queue, skipping update")
                completion()
                return
            }
        }
        
        //        playerQueueUpdateQueue.async { [weak self] in
        //            guard let self = self else { return }
        
        // For current track that needs immediate playback, ensure queue is properly built
        if let currentTrack = self.currentTrackPosition?.track,
           currentTrack.key == track.key {
            // This is the current track - ensure it's playable and queue is complete
            self.ensureCurrentTrackPlayable(track, completion: completion)
        } else {
            // For other tracks, just update them in place
            self.updateSpecificTrackInQueue(track) {
            DispatchQueue.main.async {
                completion()
            }
        }
        }
        //        }
    }
    
    /// Ensure the current track is immediately playable while maintaining full queue
    private func ensureCurrentTrackPlayable(_ track: any Track, completion: @escaping () -> Void) {
        let allTracks = tableOfContents.allTracks
        let currentItems = avQueuePlayer.items()
        
        // More conservative rebuild logic - only rebuild if queue is truly broken or very incomplete
        let hasCurrentTrackInQueue = currentItems.contains { $0.trackIdentifier == track.key }
        let hasReasonableQueue = currentItems.count >= min(10, allTracks.count * 3/4) // At least 10 items or 75% of tracks
        
        if hasCurrentTrackInQueue && hasReasonableQueue {
            // Queue is good, just update this specific track if needed
            ATLog(.debug, "🎵 [LCPPlayer] Queue is adequate (\(currentItems.count) items), updating specific track only")
            updateSpecificTrackInQueue(track) {
            DispatchQueue.main.async {
                    completion()
                }
            }
        } else {
            // Queue needs rebuilding - use the safe rebuild method
            ATLog(.debug, "🎵 [LCPPlayer] Queue inadequate (has current: \(hasCurrentTrackInQueue), count: \(currentItems.count)/\(allTracks.count)), rebuilding")
            rebuildFullQueue(completion: completion)
        }
    }
    
    /// Update a specific track's player item in the queue without rebuilding everything
    private func updateSpecificTrackInQueue(_ track: any Track, completion: @escaping () -> Void) {
        let allTracks = tableOfContents.allTracks
        guard let trackIndex = allTracks.firstIndex(where: { $0.key == track.key }) else {
            completion()
            return
        }
        
        // Build new player items for just this track
        let newPlayerItems = buildPlayerItems(fromTracks: [track])
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Find the current player items for this track in the queue
            let currentItems = self.avQueuePlayer.items()
            var itemsToReplace: [AVPlayerItem] = []
            
            // Find items that belong to this track
            for item in currentItems {
                if item.trackIdentifier == track.key {
                    itemsToReplace.append(item)
                }
            }
            
            // If we have new items for this track, replace the old ones
            if !newPlayerItems.isEmpty {
                // Remove old items for this track
                for oldItem in itemsToReplace {
                    self.avQueuePlayer.remove(oldItem)
                }
                
                // Insert new items at the correct position
                self.insertPlayerItemsAtCorrectPosition(newPlayerItems, forTrackIndex: trackIndex)
            }
            
            completion()
        }
    }
    
    // REMOVED: insertTrackIntoQueue - replaced with rebuildFullQueue for proper navigation
    // This method was problematic because it only inserted single tracks, breaking navigation
    
    private func insertPlayerItems(_ items: [AVPlayerItem]) {
        for item in items {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
            }
        }
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
    }
    
    /// Insert player items at the correct position in the queue based on track order
    private func insertPlayerItemsAtCorrectPosition(_ items: [AVPlayerItem], forTrackIndex trackIndex: Int) {
        let currentItems = avQueuePlayer.items()
        let allTracks = tableOfContents.allTracks
        
        // Find the correct insertion point by looking for the previous track's items
        var insertAfterItem: AVPlayerItem? = nil
        
        // Look backwards from current track to find where to insert
        for i in (0..<trackIndex).reversed() {
            let previousTrackKey = allTracks[i].key
            // Find the last item of the previous track
            for j in (0..<currentItems.count).reversed() {
                if currentItems[j].trackIdentifier == previousTrackKey {
                    insertAfterItem = currentItems[j]
                    break
                }
            }
            if insertAfterItem != nil { break }
        }
        
        // Insert the new items
        for item in items {
            if avQueuePlayer.canInsert(item, after: insertAfterItem) {
                avQueuePlayer.insert(item, after: insertAfterItem)
                addEndObserver(for: item)
                insertAfterItem = item // Next item should be inserted after this one
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
    }
    
    // REMOVED: Original playerItemDidReachEnd - replaced with playerItemDidFinishPlaying for better queue management
    
    private func advanceToNextTrack() {
        // Prevent auto-advances during navigation
        if isNavigating {
            ATLog(.debug, "🎵 [LCPPlayer] Skipping auto-advance during navigation")
            return
        }
        
        guard let currentTrack = currentTrackPosition?.track else {
            return
        }
        
        guard let nextTrack = tableOfContents.tracks.nextTrack(currentTrack) else {
            handlePlaybackEnd(currentTrack: currentTrack, completion: nil)
            return
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Auto-advancing to next track: \(nextTrack.key)")
        
        // With stable queue: just use AVQueuePlayer's built-in advance
        // The queue already contains all tracks, so no rebuilding needed
        if avQueuePlayer.items().count > 1 {
            avQueuePlayer.advanceToNextItem()
            ATLog(.debug, "🎵 [LCPPlayer] ✅ Used built-in advance - no queue rebuild needed")
            } else {
            // Only if queue is truly broken (shouldn't happen with stable queue)
            ATLog(.error, "🎵 [LCPPlayer] ⚠️ Queue unexpectedly small, this shouldn't happen with stable queue")
            handlePlaybackEnd(currentTrack: currentTrack, completion: nil)
        }
    }

    override public func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) else {
            completion?(currentTrackPosition)
            return
        }

        let chapterDuration = currentChapter.duration ?? 0.0
        let chapterStartTimestamp = currentChapter.position.timestamp
        
        // CRITICAL FIX: Calculate offset from chapter start, not track start
        let offsetWithinChapter = value * chapterDuration
        let absoluteTimestamp = chapterStartTimestamp + offsetWithinChapter
        
        // BOUNDARY VALIDATION: Ensure we don't seek beyond chapter boundaries
        let maxTimestamp = chapterStartTimestamp + chapterDuration
        let trackDuration = currentChapter.position.track.duration
        let clampedTimestamp = min(absoluteTimestamp, min(maxTimestamp, trackDuration))
        
        // Create new position with correct timestamp relative to chapter start
        let newPosition = TrackPosition(
            track: currentChapter.position.track,
            timestamp: clampedTimestamp,
            tracks: currentTrackPosition.tracks
        )
        
        // Use enhanced logging system
        logSeek(
            action: "SLIDER_DRAG",
            from: currentTrackPosition,
            to: newPosition,
            sliderValue: value,
            success: true
        )

        decryptTrackIfNeeded(track: newPosition.track) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.rebuildQueueForPosition(newPosition) {
                    self.performSuperSeek(to: newPosition, completion: completion)
                }
            } else {
                completion?(nil)
            }
        }
    }

    override public func handlePlaybackEnd(currentTrack: any Track, completion: ((TrackPosition?) -> Void)?) {
        // At end-of-book, pause and emit event. Do not rebuild/reset to chapter 1.
                avQueuePlayer.pause()
        ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
        playbackStatePublisher.send(.bookCompleted)
        completion?(currentTrackPosition)
    }
    
    // DEPRECATED: Old queue rebuilding approach - no longer needed with stable queue architecture
    // This method should rarely be called now that we build the queue once and update smartly
    private func rebuildFullQueue(completion: @escaping () -> Void = {}) {
        ATLog(.debug, "🎵 [LCPPlayer] ⚠️ DEPRECATED: rebuildFullQueue called - stable queue should avoid this")
        
        // For now, just rebuild the queue if absolutely necessary (error recovery)
        queueBuiltSuccessfully = false
        buildPlayerQueue()
        completion()
    }
    
    private func rebuildQueueForPosition(_ position: TrackPosition, completion: @escaping () -> Void) {
        // For position-based rebuilds, use the full queue method for consistency
        ATLog(.debug, "🎵 [LCPPlayer] Rebuilding queue for position - using full queue")
        rebuildFullQueue(completion: completion)
    }

    override func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        guard let delegate = decryptionDelegate,
              let task = task as? LCPDownloadTask,
              let decryptedUrls = task.decryptedUrls else {
            return .unknown
        }

        var savedUrls = [URL]()
        var missingUrls = [URL]()

        let group = DispatchGroup()

        for (index, decryptedUrl) in decryptedUrls.enumerated() {
            if FileManager.default.fileExists(atPath: decryptedUrl.path) {
                savedUrls.append(decryptedUrl)
                continue
            }

            group.enter()
            decryptionQueue.async {
                delegate.decrypt(url: task.urls[index], to: decryptedUrl) { error in
                    if let error = error {
                        ATLog(.error, "Error decrypting file", error: error)
                    } else {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: self.taskCompleteNotification, object: task)
                            task.statePublisher.send(.completed)
                        }
                    }
                    group.leave()
                }
            }

            missingUrls.append(task.urls[index])
        }

        group.wait()

        return missingUrls.isEmpty ? .saved(savedUrls) : .missing(missingUrls)
    }
    
    
    
    /// Improved resource loading strategy: prioritize local files, fall back to streaming with retry logic
    private func loadStreamingResourceForTrack(_ track: any Track) {
        guard let decryptorDelegate = decryptionDelegate,
              let lcpTrack = track as? LCPTrack else {
            return
        }
        
        // First, check if local files are available (highest priority)
        if lcpTrack.hasLocalFiles() {
            ATLog(.debug, "🎵 [LCPPlayer] ✅ Track \(track.key) has local files, no streaming needed")
            return
        }
        
        // If streaming resource already exists, don't load again
        if lcpTrack.streamingResource != nil {
            ATLog(.debug, "🎵 [LCPPlayer] Track \(track.key) already has streaming resource")
            return
        }
        
        guard let trackPath = track.urls?.first?.path else {
            ATLog(.error, "🎵 [LCPPlayer] ❌ No track path available for \(track.key)")
            return
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Loading streaming resource for track: \(track.key)")
        
        // Attempt to get streaming URL with retry logic
        attemptStreamingResourceLoad(for: track, trackPath: trackPath, lcpTrack: lcpTrack, attempt: 1)
    }
    
    /// Attempt streaming resource load with exponential backoff retry
    private func attemptStreamingResourceLoad(for track: any Track, trackPath: String, lcpTrack: LCPTrack, attempt: Int) {
        let maxAttempts = 3
        let baseDelay: TimeInterval = 0.5
        
        guard let decryptorDelegate = decryptionDelegate,
              let getStreamableURL = decryptorDelegate.getStreamableURL else {
            ATLog(.error, "🎵 [LCPPlayer] ❌ No decryption delegate or streaming URL method available")
            return
        }
        
        getStreamableURL(trackPath) { [weak self, weak lcpTrack] streamingURL, error in
            DispatchQueue.main.async {
                guard let self = self, self.isActive, let lcpTrack else { return }
                
                if let error = error {
                    ATLog(.error, "🎵 [LCPPlayer] ❌ Attempt \(attempt)/\(maxAttempts) failed for \(track.key): \(error.localizedDescription)")
                    
                    // Retry with exponential backoff if we haven't reached max attempts
                    if attempt < maxAttempts {
                        let delay = baseDelay * pow(2.0, Double(attempt - 1))
                        ATLog(.debug, "🎵 [LCPPlayer] 🔄 Retrying in \(delay)s...")
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.attemptStreamingResourceLoad(for: track, trackPath: trackPath, lcpTrack: lcpTrack, attempt: attempt + 1)
                        }
                    } else {
                        ATLog(.error, "🎵 [LCPPlayer] ❌ Failed to load streaming resource for \(track.key) after \(maxAttempts) attempts")
                        // Try to initiate background decryption as final fallback
                        self.tryBackgroundDecryption(for: track)
                    }
                    return
                }
                
                guard let streamingURL = streamingURL else {
                    ATLog(.error, "🎵 [LCPPlayer] ❌ No streaming URL returned for \(track.key)")
                    if attempt < maxAttempts {
                        let delay = baseDelay * pow(2.0, Double(attempt - 1))
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.attemptStreamingResourceLoad(for: track, trackPath: trackPath, lcpTrack: lcpTrack, attempt: attempt + 1)
                        }
                    }
                    return
                }
                
                ATLog(.debug, "🎵 [LCPPlayer] ✅ Got streaming resource for \(track.key): \(streamingURL.absoluteString)")
                lcpTrack.setStreamingResource(streamingURL)
                
                // Update player queue if this is the current track
                if let currentTrack = self.currentTrackPosition?.track,
                   currentTrack.key == track.key {
                    ATLog(.debug, "🎵 [LCPPlayer] Streaming resource ready for current track, updating queue")
                    self.updatePlayerQueueForStreamingTrack(track)
                    
                    // Try to start playback if needed
                    if self.avQueuePlayer.timeControlStatus != .playing {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.avQueuePlayer.play()
                        }
                    }
                } else {
                    ATLog(.debug, "🎵 [LCPPlayer] Streaming resource loaded for preloaded track: \(track.key)")
                }
            }
        }
    }
    
    /// Initiate background decryption as fallback when streaming fails
    private func tryBackgroundDecryption(for track: any Track) {
        guard let lcpTask = track.downloadTask as? LCPDownloadTask,
              let decryptedUrls = lcpTask.decryptedUrls else {
            ATLog(.error, "🎵 [LCPPlayer] ❌ No decryption task available for fallback on track: \(track.key)")
            return
        }
        
        // Check if any files are missing and need decryption
        let missingFiles = decryptedUrls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        
        if !missingFiles.isEmpty {
            ATLog(.debug, "🎵 [LCPPlayer] 🔄 Starting background decryption for \(missingFiles.count) missing files for track: \(track.key)")
            performLocalDecrypt(missingFiles, using: lcpTask) { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        ATLog(.debug, "🎵 [LCPPlayer] ✅ Background decryption completed for track: \(track.key)")
                        // Update the queue now that local files are available
                        self?.updatePlayerQueueForLocalTrack(track)
                    } else {
                        ATLog(.error, "🎵 [LCPPlayer] ❌ Background decryption failed for track: \(track.key)")
                    }
                }
            }
        } else {
            ATLog(.debug, "🎵 [LCPPlayer] Local files exist but might not be detected properly for track: \(track.key)")
        }
    }
    
    
    
    /// Update player queue when streaming resource becomes available for current track
    private func updatePlayerQueueForStreamingTrack(_ track: any Track) {
        ATLog(.debug, "🎵 [LCPPlayer] Updating player queue for streaming track: \(track.key)")
        
        // Use the smart update method instead of rebuilding the entire queue
        updateSpecificTrackInQueue(track) {
            ATLog(.debug, "🎵 [LCPPlayer] Player queue updated with streaming resource for track: \(track.key)")
        }
    }
    
    /// Update player queue when local files become available for a track
    private func updatePlayerQueueForLocalTrack(_ track: any Track) {
        ATLog(.debug, "🎵 [LCPPlayer] Updating player queue for local track: \(track.key)")
        
        updateSpecificTrackInQueue(track) {
            ATLog(.debug, "🎵 [LCPPlayer] ✅ Player queue updated for local track: \(track.key)")
        }
    }
    
    override func unload() {
        isActive = false
        
        // Stop queue monitoring timer
        queueMonitoringTimer?.invalidate()
        queueMonitoringTimer = nil
        
        // Remove per-item observers to avoid KVO crashes
        safeRemoveAllObservers()
        trackToItemMapping.removeAll()
        super.unload()
    }
}

