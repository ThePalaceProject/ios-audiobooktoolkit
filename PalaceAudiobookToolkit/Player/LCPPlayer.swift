//
//  LCPPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/16/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation

class LCPPlayer: OpenAccessPlayer {
    
    var decryptionDelegate: DRMDecryptor?
    private let decryptionQueue = DispatchQueue(label: "com.palace.LCPPlayer.decryptionQueue", qos: .background)
    private let playerQueueUpdateQueue = DispatchQueue(label: "com.palace.LCPPlayer.playerQueueUpdateQueue", qos: .userInitiated)
    private let decryptionLock = NSLock()
    
    /// Flag to prevent starting downloads multiple times
    private var hasStartedPrioritizedDownloads = false
    
    override var taskCompleteNotification: Notification.Name {
        LCPDownloadTaskCompleteNotification
    }

    override var currentOffset: Double {
        guard let currentTrackPosition, let currentChapter else {
            return 0
        }

        let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
        return offset
    }

    init(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) {
        self.decryptionDelegate = decryptor
        super.init(tableOfContents: tableOfContents)
        configurePlayer()
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        super.init(tableOfContents: tableOfContents)
        configurePlayer()
    }
    
    override func configurePlayer() {
        setupAudioSession()
        loadInitialPlayerQueue()
        addPlayerObservers()
    }
    
    private func loadInitialPlayerQueue() {
        ATLog(.debug, "🎵 [LCPPlayer] loadInitialPlayerQueue - calling buildPlayerQueue for lazy loading")
        // Use our lazy loading buildPlayerQueue override instead of manual track loading
        buildPlayerQueue()
    }
    
    override public func play() {
        ATLog(.debug, "🎵 [LCPPlayer] play() called")
        super.play()
    }
    
    override public func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        ATLog(.debug, "🎵 [LCPPlayer] play(at position) called for track: \(position.track.title ?? "unknown")")
        
        // Start prioritized downloads when user actually tries to play
        startPrioritizedDownloadsIfNeeded()
        
        // Ensure the requested track and surrounding tracks are loaded
        ensureTracksLoadedAroundPosition(position)
        
        // All LCP tracks now use the decrypt() method for both local and streaming
        
        // For traditional LCP tracks, decrypt first
        ATLog(.debug, "🎵 [LCPPlayer] Traditional LCP track, decrypting first")
        decryptTrackIfNeeded(track: position.track) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.updateQueueForTrack(position.track) {
                    self.performSuperPlay(at: position, completion: completion)
                }
            } else {
                completion?(NSError(domain: "com.palace.LCPPlayer", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to decrypt track"]))
            }
        }
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
        let newPosition = currentTrackPosition + timeInterval
        decryptTrackIfNeeded(track: newPosition.track) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.updateQueueForTrack(newPosition.track) {
                    self.performSuperSeek(to: newPosition, completion: completion)
                }
            } else {
                completion?(nil)
            }
        }
    }
    
    private func performSuperPlay(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        super.play(at: position, completion: completion)
    }
    
    private func performSuperSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
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
                self.decryptionLock.lock()
                self.decryptionDelegate?.decrypt(url: task.urls[idx], to: dest) { err in
                    if err != nil { success = false }
                    self.decryptionLock.unlock()
                    group.leave()
                }
            }
            
            group.notify(queue: DispatchQueue.main) {
                completion(success)
            }
        })
    }

    
    /// Override buildPlayerQueue to load all tracks but fetch streaming resources on-demand
    override public func buildPlayerQueue() {
        ATLog(.debug, "🎵 [LCPPlayer] Building player queue with all tracks (streaming resources loaded on-demand)")
        resetPlayerQueue()
        
        // Load all tracks for full player queue
        let allTracks = tableOfContents.allTracks
        let playerItems = buildPlayerItems(fromTracks: allTracks)
        
        if playerItems.isEmpty {
            isLoaded = false
            return
        }
        
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        isLoaded = true
        
        ATLog(.debug, "🎵 [LCPPlayer] Player queue built with \(playerItems.count) items, ready for presentation")
    }
    
    /// Override buildPlayerItems to handle local files and smart streaming
    override public func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
        var items = [AVPlayerItem]()
        
        ATLog(.debug, "🎵 [LCPPlayer] Building player items for \(tracks.count) tracks")
        
        for track in tracks {
            
            // Handle LCP tracks - prefer local files, use streaming resource as fallback
            if let lcpTrack = track as? LCPTrack {
                ATLog(.debug, "🎵 [LCPPlayer] Processing LCP track: \(track.key)")
                
                // First priority: Use local files if available
                if lcpTrack.hasLocalFiles(),
                   let lcpTask = track.downloadTask as? LCPDownloadTask,
                   let decryptedUrls = lcpTask.decryptedUrls {
                    ATLog(.debug, "🎵 [LCPPlayer] ✅ Using LOCAL files for track: \(track.key)")
                    for url in decryptedUrls {
                        let playerItem = AVPlayerItem(url: url)
                        playerItem.audioTimePitchAlgorithm = .timeDomain
                        playerItem.trackIdentifier = track.key
                        items.append(playerItem)
                    }
                }
                // Second priority: Use streaming resource if available
                else if let streamingResource = lcpTrack.streamingResource {
                    ATLog(.debug, "🎵 [LCPPlayer] 🌊 Using STREAMING resource for track: \(track.key)")
                    let playerItem = AVPlayerItem(url: streamingResource)
                    playerItem.audioTimePitchAlgorithm = .timeDomain
                    playerItem.trackIdentifier = track.key
                    items.append(playerItem)
                }
                // Third priority: Use original URL as placeholder (streaming will be loaded on-demand)
                else if let originalUrl = track.urls?.first {
                    ATLog(.debug, "🎵 [LCPPlayer] 📥 Using placeholder URL for track: \(track.key) (streaming on-demand)")
                    let playerItem = AVPlayerItem(url: originalUrl)
                    playerItem.audioTimePitchAlgorithm = .timeDomain
                    playerItem.trackIdentifier = track.key
                    items.append(playerItem)
                }
                continue
            }
            
            // Handle traditional LCP tracks (local files only)
            if let lcpTask = track.downloadTask as? LCPDownloadTask,
               let decryptedUrls = lcpTask.decryptedUrls {
                let availableUrls = decryptedUrls.filter { FileManager.default.fileExists(atPath: $0.path) }
                
                if !availableUrls.isEmpty {
                    // Use local files
                    ATLog(.debug, "🎵 [LCPPlayer] Using local files for traditional LCP track: \(track.key)")
                    for url in availableUrls {
                        let playerItem = AVPlayerItem(url: url)
                        playerItem.audioTimePitchAlgorithm = .timeDomain
                        playerItem.trackIdentifier = track.key
                        items.append(playerItem)
                    }
                    continue
                } else {
                    // Need to decrypt files first
                    ATLog(.debug, "🎵 [LCPPlayer] Need to decrypt traditional LCP track: \(track.key)")
                    // Fall back to parent class handling for decryption
                }
            }
            
            // Fall back to parent class handling for other cases
            guard let fileStatus = assetFileStatus(track.downloadTask) else {
                continue
            }
            
            switch fileStatus {
            case .saved(let urls):
                for url in urls {
                    let playerItem = AVPlayerItem(url: url)
                    playerItem.audioTimePitchAlgorithm = .timeDomain
                    playerItem.trackIdentifier = track.key
                    items.append(playerItem)
                }
            case .missing:
                listenForDownloadCompletion(task: track.downloadTask)
                continue
            case .unknown:
                continue
            }
        }
        return items
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
            // No current track, just start downloading the first few tracks
            startDownloadsForInitialTracks(tracks)
            return
        }
        
        let currentIndex = currentTrack.index
        let maxTracksToDownload = 3 // Download current track + 2 nearby tracks
        
        // Create prioritized list: current track, then next track, then previous track, etc.
        var prioritizedIndices: [Int] = [currentIndex]
        
        for offset in 1...maxTracksToDownload {
            if currentIndex + offset < tracks.count {
                prioritizedIndices.append(currentIndex + offset)
            }
            if currentIndex - offset >= 0 {
                prioritizedIndices.append(currentIndex - offset)
            }
        }
        
        // Start downloads for prioritized tracks (using traditional LCPDownloadTask)
        for index in prioritizedIndices {
            guard index < tracks.count,
                  let lcpTask = tracks[index].downloadTask as? LCPDownloadTask else {
                continue
            }
            
            // Traditional LCP downloads will be handled by the existing download system
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
        playerQueueUpdateQueue.async { [weak self] in
            guard let self = self else { return }
            let playerItems = self.buildPlayerItems(fromTracks: [track])
            
            DispatchQueue.main.async {
                self.insertPlayerItems(playerItems)
                completion()
            }
        }
    }
    
    private func insertTrackIntoQueue(track: any Track) {
        playerQueueUpdateQueue.async { [weak self] in
            guard let self = self else { return }
            let playerItems = self.buildPlayerItems(fromTracks: [track])
            
            DispatchQueue.main.async {
                self.insertPlayerItems(playerItems)
                self.isLoaded = true
            }
        }
    }
    
    private func insertPlayerItems(_ items: [AVPlayerItem]) {
        for item in items {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
            }
        }
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
    }
    
    @objc override func playerItemDidReachEnd(_ notification: Notification) {
        if let currentTrackPosition = currentTrackPosition,
           let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) {
            playbackStatePublisher.send(.completed(currentChapter))
        }
        advanceToNextTrack()
    }
    
    private func advanceToNextTrack() {
        guard let currentTrack = currentTrackPosition?.track else {
            return
        }
        
        guard let nextTrack = tableOfContents.tracks.nextTrack(currentTrack) else {
            handlePlaybackEnd(currentTrack: currentTrack, completion: nil)
            return
        }
        
        decryptTrackIfNeeded(track: nextTrack) { [weak self] success in
            guard let self = self else { return }
            
            if success {
                resetPlayerQueue()
                self.insertTrackIntoQueue(track: nextTrack)
            } else {
                self.handlePlaybackEnd(currentTrack: currentTrack, completion: nil)
            }
        }
    }

    override public func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) else {
            completion?(currentTrackPosition)
            return
        }

        let chapterDuration = currentChapter.duration ?? 0.0
        let offset = value * chapterDuration
        var newPosition = currentTrackPosition
        newPosition.timestamp = offset

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
        defer {
            if let currentTrackPosition, let firstTrack = currentTrackPosition.tracks.first {
                let endPosition = TrackPosition(
                    track: firstTrack,
                    timestamp: 0.0,
                    tracks: currentTrackPosition.tracks
                )

                avQueuePlayer.pause()
                loadInitialPlayerQueue()
                completion?(endPosition)
            }
        }

        ATLog(.debug, "End of book reached. No more tracks to absorb the remaining time.")
        playbackStatePublisher.send(.bookCompleted)
    }

    private func rebuildQueueForPosition(_ position: TrackPosition, completion: @escaping () -> Void) {
        playerQueueUpdateQueue.async { [weak self] in
            guard let self = self else { return }
            
            ATLog(.debug, "🎵 [LCPPlayer] Rebuilding queue for position (lazy loading)")
            self.resetPlayerQueue()
            
            var tracksToLoad: [any Track] = []
            
            if let currentTrack = self.tableOfContents.track(forKey: position.track.key) {
                tracksToLoad.append(currentTrack)
            }
            
            // Only load a few tracks around the current position (lazy loading)
            var nextTrack = self.tableOfContents.tracks.nextTrack(position.track)
            while let track = nextTrack, tracksToLoad.count < 4 {  // Current + next 3
                tracksToLoad.append(track)
                nextTrack = self.tableOfContents.tracks.nextTrack(track)
            }
            
            ATLog(.debug, "🎵 [LCPPlayer] Rebuilding with \(tracksToLoad.count) tracks (not all \(self.tableOfContents.allTracks.count))")
            let playerItems = self.buildPlayerItems(fromTracks: tracksToLoad)
            
            DispatchQueue.main.async {
                self.insertPlayerItems(playerItems)
                completion()
            }
        }
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
    

    
    /// Load streaming resource for a specific track when needed
    private func loadStreamingResourceForTrack(_ track: any Track) {
        guard let decryptorDelegate = decryptionDelegate,
              let lcpTrack = track as? LCPTrack,
              !lcpTrack.hasLocalFiles(),
              lcpTrack.streamingResource == nil,
              let trackPath = track.urls?.first?.path else {
            return
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Loading streaming resource for track: \(track.key)")
        
        if let getStreamableURL = decryptorDelegate.getStreamableURL {
            getStreamableURL(trackPath) { [weak self, weak lcpTrack] streamingURL, error in
                DispatchQueue.main.async {
                    if let error = error {
                        ATLog(.error, "🎵 [LCPPlayer] Failed to get streaming resource for \(track.key): \(error.localizedDescription)")
                    } else if let streamingURL = streamingURL {
                        ATLog(.debug, "🎵 [LCPPlayer] ✅ Got streaming resource for \(track.key): \(streamingURL.absoluteString)")
                        lcpTrack?.setStreamingResource(streamingURL)
                        
                        // Update player queue if this is the current track
                        if let currentTrack = self?.currentTrackPosition?.track,
                           currentTrack.key == track.key {
                            self?.rebuildPlayerQueueForStreamingTrack(track)
                        }
                    }
                }
            }
        }
    }
    
    /// Rebuild player queue when streaming resource becomes available for current track
    private func rebuildPlayerQueueForStreamingTrack(_ track: any Track) {
        ATLog(.debug, "🎵 [LCPPlayer] Rebuilding player queue for streaming track: \(track.key)")
        
        // Get current time before rebuilding
        let currentTime = avQueuePlayer.currentTime()
        
        // Clear and rebuild queue
        avQueuePlayer.removeAllItems()
        
        let playerItems = buildPlayerItems(fromTracks: tableOfContents.allTracks)
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
                addEndObserver(for: item)
            }
        }
        
        // Resume from previous position
        if currentTime != CMTime.zero {
            avQueuePlayer.seek(to: currentTime)
        }
        
        ATLog(.debug, "🎵 [LCPPlayer] Player queue rebuilt with streaming resource")
    }
}
