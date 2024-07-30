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
    private var decryptionQueue = DispatchQueue(label: "com.palace.LCPPlayer.decryptionQueue", qos: .background, attributes: .concurrent)
    private var playerQueueUpdateQueue = DispatchQueue(label: "com.palace.LCPPlayer.playerQueueUpdateQueue", qos: .userInitiated)
    
    override var taskCompleteNotification: Notification.Name {
        LCPDownloadTaskCompleteNotification
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
    
    public func loadInitialPlayerQueue() {
        resetPlayerQueue()
        
        guard let firstTrack = tableOfContents.allTracks.first else {
            isLoaded = false
            return
        }
        
        decryptTrackIfNeeded(track: firstTrack) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.playerQueueUpdateQueue.async {
                    let playerItems = self.buildPlayerItems(fromTracks: [firstTrack])
                    DispatchQueue.main.async {
                        for item in playerItems {
                            if self.avQueuePlayer.canInsert(item, after: nil) {
                                self.avQueuePlayer.insert(item, after: nil)
                                self.addEndObserver(for: item)
                            }
                        }
                        self.isLoaded = true
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.isLoaded = false
                }
            }
        }
    }
    
    override public func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        decryptTrackIfNeeded(track: position.track) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.updateQueueForTrack(position.track) {
                    self.invokeSuperPlay(at: position, completion: completion)
                }
            } else {
                completion?(NSError(domain: "com.palace.LCPPlayer", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to decrypt track"]))
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
                    self.invokeSuperSeek(to: newPosition, completion: completion)
                }
            } else {
                completion?(nil)
            }
        }
    }
    
    private func invokeSuperPlay(at position: TrackPosition, completion: ((Error?) -> Void)?) {
        super.play(at: position, completion: completion)
    }
    
    private func invokeSuperSeek(to position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
        super.seekTo(position: position, completion: completion)
    }
    
    private func decryptTrackIfNeeded(track: any Track, completion: @escaping (Bool) -> Void) {
        guard let task = track.downloadTask as? LCPDownloadTask, let decryptedUrls = task.decryptedUrls else {
            completion(false)
            return
        }
        
        let missingUrls = decryptedUrls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        
        if missingUrls.isEmpty {
            completion(true)
            return
        }
        
        decryptionQueue.async(group: nil, qos: .background, flags: .barrier) {
            let group = DispatchGroup()
            var success = true
            
            for (index, decryptedUrl) in decryptedUrls.enumerated() where missingUrls.contains(decryptedUrl) {
                group.enter()
                self.decryptionDelegate?.decrypt(url: task.urls[index], to: decryptedUrl) { error in
                    if let error = error {
                        ATLog(.error, "Error decrypting file", error: error)
                        success = false
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                completion(success)
            }
        }
    }
    
    private func updateQueueForTrack(_ track: any Track, completion: @escaping () -> Void) {
        playerQueueUpdateQueue.async { [weak self] in
            guard let self = self else { return }
            let playerItems = self.buildPlayerItems(fromTracks: [track])
            
            DispatchQueue.main.async {
                for item in playerItems {
                    if self.avQueuePlayer.canInsert(item, after: nil) {
                        self.avQueuePlayer.insert(item, after: nil)
                    }
                }
                self.avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
                completion()
            }
        }
    }
    
    @objc override func playerItemDidReachEnd(_ notification: Notification) {
        if let currentTrackPosition = currentTrackPosition,
           let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) {
            playbackStatePublisher.send(.completed(currentChapter))
        }
    }

    override public func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
        guard let currentTrackPosition = currentTrackPosition,
              let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition) else {
            completion?(currentTrackPosition)
            return
        }
        
        let newPosition = currentChapter.position + value * (currentChapter.duration ?? 0.0)
        
        decryptTrackIfNeeded(track: newPosition.track) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.rebuildQueueForPosition(newPosition) {
                    self.invokeSuperSeek(to: newPosition, completion: completion)
                }
            } else {
                completion?(nil)
            }
        }
    }
    
    private func rebuildQueueForPosition(_ position: TrackPosition, completion: @escaping () -> Void) {
        playerQueueUpdateQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.resetPlayerQueue()
            
            var tracksToLoad: [any Track] = []
            
            if let currentTrack = self.tableOfContents.track(forKey: position.track.key) {
                tracksToLoad.append(currentTrack)
            }
            
            var nextTrack = self.tableOfContents.tracks.nextTrack(position.track)
            while let track = nextTrack, tracksToLoad.count < 3 {
                tracksToLoad.append(track)
                nextTrack = self.tableOfContents.tracks.nextTrack(track)
            }
            
            let playerItems = self.buildPlayerItems(fromTracks: tracksToLoad)
            
            DispatchQueue.main.async {
                for item in playerItems {
                    if self.avQueuePlayer.canInsert(item, after: nil) {
                        self.avQueuePlayer.insert(item, after: nil)
                        self.addEndObserver(for: item)
                    }
                }
                completion()
            }
        }
    }
    
    override func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        guard let delegate = decryptionDelegate, let task = task as? LCPDownloadTask, let decryptedUrls = task.decryptedUrls else {
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
        
        guard missingUrls.count == 0 else {
            return .missing(missingUrls)
        }
        
        return .saved(savedUrls)
    }
}
