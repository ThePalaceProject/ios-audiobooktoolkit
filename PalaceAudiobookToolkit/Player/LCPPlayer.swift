//
//  LCPPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/16/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

//import AVFoundation
//
//class LCPPlayer: OpenAccessPlayer {
//    
//    var decryptionDelegate: DRMDecryptor?
//    
//    override var taskCompleteNotification: Notification.Name {
//        return LCPDownloadTaskCompleteNotification
//    }
//    
//    /// Audio file status. LCP audiobooks contain all encrypted audio files inside, this method returns the status of decrypted versions of these files.
//    /// - Parameter task: `LCPDownloadTask` containing internal URL (e.g., `media/sound.mp3`) for decryption.
//    /// - Returns: Status of the file, .unknown in case of an error, .missing if the file needs decryption, .saved when accessing an already decrypted file.
//    override func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
//        if let delegate = decryptionDelegate, let task = task as? LCPDownloadTask, let decryptedUrls = task.decryptedUrls {
//            var savedUrls = [URL]()
//            var missingUrls = [URL]()
//            
//            for (index, decryptedUrl) in decryptedUrls.enumerated() {
//                // Return file URL if it is already decrypted
//                if FileManager.default.fileExists(atPath: decryptedUrl.path) {
//                    savedUrls.append(decryptedUrl)
//                    continue
//                }
//                
//                // Decrypt, return .missing to wait for decryption
//                delegate.decrypt(url: task.urls[index], to: decryptedUrl) { error in
//                    if let error = error {
//                        ATLog(.error, "Error decrypting file", error: error)
//                        return
//                    }
//                    DispatchQueue.main.async {
//                        NotificationCenter.default.post(name: self.taskCompleteNotification, object: task)
//                        task.statePublisher.send(.completed)
//                    }
//                }
//                
//                missingUrls.append(task.urls[index])
//            }
//            
//            guard missingUrls.count == 0 else {
//                return .missing(missingUrls)
//            }
//            
//            return .saved(savedUrls)
//        } else {
//            return .unknown
//        }
//    }
//    
//    /// Audiobook player
//    /// - Parameters:
//    ///   - tableOfContents: Audiobook player's table of contents.
//    ///   - decryptor: LCP DRM decryptor.
//    init(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) {
//        self.decryptionDelegate = decryptor
//        super.init(tableOfContents: tableOfContents)
//    }
//    
//    required init(tableOfContents: AudiobookTableOfContents) {
//        super.init(tableOfContents: tableOfContents)
//        configurePlayer()
//    }
//    
//    override func configurePlayer() {
//        setupAudioSession()
//        loadInitialPlayerQueue()
//        addPlayerObservers()
//    }
//    
//    public func loadInitialPlayerQueue() {
//        resetPlayerQueue()
//        
//        let initialTracks = Array(arrayLiteral: tableOfContents.allTracks[0])
//        let playerItems = buildPlayerItems(fromTracks: initialTracks)
//        
//        for item in playerItems {
//            if avQueuePlayer.canInsert(item, after: nil) {
//                avQueuePlayer.insert(item, after: nil)
//            }
//        }
//        
//        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
//        isLoaded = true
//    }
//    
//    override public func rebuildPlayerQueueAndNavigate(
//        to trackPosition: TrackPosition?,
//        completion: ((Bool) -> Void)? = nil
//    ) {
//        avQueuePlayer.removeAllItems()
//        
//        guard let trackPosition = trackPosition else {
//            completion?(false)
//            return
//        }
//        
//        let playerItems = buildPlayerItems(fromTracks: [trackPosition.track])
//        
//        guard let item = playerItems.first else {
//            completion?(false)
//            return
//        }
//        
//        if avQueuePlayer.canInsert(item, after: nil) {
//            avQueuePlayer.insert(item, after: nil)
//            navigateToItem(at: 0, with: trackPosition.timestamp, completion: completion)
//        } else {
//            completion?(false)
//        }
//    }
//    
//    override func playerItemDidReachEnd(_ notification: Notification) {
//        super.playerItemDidReachEnd(notification)
//        
//        // Load the next track dynamically
//        loadNextTrack()
//    }
//    
//    private func loadNextTrack() {
//        guard let currentTrack = currentTrackPosition?.track,
//              let nextTrack = tableOfContents.tracks.nextTrack(currentTrack),
//              avQueuePlayer.items().count <= 3 else { // Maintain a queue size of up to 3 items
//            return
//        }
//        
//        let nextPlayerItem = buildPlayerItems(fromTracks: [nextTrack])
//        if let item = nextPlayerItem.first, avQueuePlayer.canInsert(item, after: nil) {
//            avQueuePlayer.insert(item, after: nil)
//        }
//    }
//    
//    override public func buildPlayerQueue() {
//        resetPlayerQueue()
//        
//        guard let firstTrack = tableOfContents.allTracks.first else {
//            isLoaded = false
//            return
//        }
//        
//        let playerItems = buildPlayerItems(fromTracks: [firstTrack])
//        if playerItems.isEmpty {
//            isLoaded = false
//            return
//        }
//        
//        for item in playerItems {
//            if avQueuePlayer.canInsert(item, after: nil) {
//                avQueuePlayer.insert(item, after: nil)
//            } else {
//                isLoaded = avQueuePlayer.items().count > 0
//                return
//            }
//        }
//        
//        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
//        isLoaded = true
//    }
//}

import AVFoundation

class LCPPlayer: OpenAccessPlayer {
    
    var decryptionDelegate: DRMDecryptor?
    private var decryptionQueue = DispatchQueue(label: "com.palace.LCPPlayer.decryptionQueue", qos: .background)
    
    override var taskCompleteNotification: Notification.Name {
        return LCPDownloadTaskCompleteNotification
    }
    
    override func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        if let delegate = decryptionDelegate, let task = task as? LCPDownloadTask, let decryptedUrls = task.decryptedUrls {
            var savedUrls = [URL]()
            var missingUrls = [URL]()
            
            for (index, decryptedUrl) in decryptedUrls.enumerated() {
                // Return file URL if it is already decrypted
                if FileManager.default.fileExists(atPath: decryptedUrl.path) {
                    savedUrls.append(decryptedUrl)
                    continue
                }
                
                // Decrypt, return .missing to wait for decryption
                delegate.decrypt(url: task.urls[index], to: decryptedUrl) { error in
                    if let error = error {
                        ATLog(.error, "Error decrypting file", error: error)
                        return
                    }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: self.taskCompleteNotification, object: task)
                        task.statePublisher.send(.completed)
                    }
                }
                
                missingUrls.append(task.urls[index])
            }
            
            guard missingUrls.count == 0 else {
                return .missing(missingUrls)
            }
            
            return .saved(savedUrls)
        } else {
            return .unknown
        }
    }
    
    init(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) {
        self.decryptionDelegate = decryptor
        super.init(tableOfContents: tableOfContents)
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        super.init(tableOfContents: tableOfContents)
        configurePlayer()
    }
    
    override func configurePlayer() {
        setupAudioSession()
        loadInitialPlayerQueue()
        addPlayerObservers()
        decryptRemainingTracksInBackground()
    }
    
    public func loadInitialPlayerQueue() {
        resetPlayerQueue()
        
        guard let firstTrack = tableOfContents.allTracks.first else {
            isLoaded = false
            return
        }
        
        let playerItems = buildPlayerItems(fromTracks: [firstTrack])
        
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        isLoaded = true
    }
    
    override public func rebuildPlayerQueueAndNavigate(
        to trackPosition: TrackPosition?,
        completion: ((Bool) -> Void)? = nil
    ) {
        avQueuePlayer.removeAllItems()
        
        guard let trackPosition = trackPosition else {
            completion?(false)
            return
        }
        
        let playerItems = buildPlayerItems(fromTracks: [trackPosition.track])
        
        guard let item = playerItems.first else {
            completion?(false)
            return
        }
        
        if avQueuePlayer.canInsert(item, after: nil) {
            avQueuePlayer.insert(item, after: nil)
            navigateToItem(at: 0, with: trackPosition.timestamp, completion: completion)
        } else {
            completion?(false)
        }
    }
    
    override func playerItemDidReachEnd(_ notification: Notification) {
        super.playerItemDidReachEnd(notification)
        loadNextTrack()
    }
    
    private func loadNextTrack() {
        guard let currentTrack = currentTrackPosition?.track,
              let nextTrack = tableOfContents.tracks.nextTrack(currentTrack),
              avQueuePlayer.items().count <= 3 else { // Maintain a queue size of up to 3 items
            return
        }
        
        let nextPlayerItem = buildPlayerItems(fromTracks: [nextTrack])
        if let item = nextPlayerItem.first, avQueuePlayer.canInsert(item, after: nil) {
            avQueuePlayer.insert(item, after: nil)
        }
    }
    
    override public func buildPlayerQueue() {
        resetPlayerQueue()
        
        guard let firstTrack = tableOfContents.allTracks.first else {
            isLoaded = false
            return
        }
        
        let playerItems = buildPlayerItems(fromTracks: [firstTrack])
        if playerItems.isEmpty {
            isLoaded = false
            return
        }
        
        for item in playerItems {
            if avQueuePlayer.canInsert(item, after: nil) {
                avQueuePlayer.insert(item, after: nil)
            } else {
                isLoaded = avQueuePlayer.items().count > 0
                return
            }
        }
        
        avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
        isLoaded = true
    }
    
    private func decryptRemainingTracksInBackground() {
        decryptionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let remainingTracks = Array(self.tableOfContents.allTracks.dropFirst())
            let batchSize = 3 // Number of tracks to decrypt at once
            
            for batch in stride(from: 0, to: remainingTracks.count, by: batchSize) {
                let endIndex = min(batch + batchSize, remainingTracks.count)
                let batchTracks = Array(remainingTracks[batch..<endIndex])
                
                self.decryptBatch(tracks: batchTracks)
            }
        }
    }
    
    private func decryptBatch(tracks: [any Track]) {
        for track in tracks {
            guard let task = track.downloadTask as? LCPDownloadTask else { continue }
            
            _ = self.assetFileStatus(task)
        }
    }
}
