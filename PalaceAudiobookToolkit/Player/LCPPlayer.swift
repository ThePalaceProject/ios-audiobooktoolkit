//
//  LCPPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/16/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation

class LCPPlayer: OpenAccessPlayer {
    
    // DRMDecryptor passed from SimplyE to process encrypted audio files.
    var decryptionDelegate: DRMDecryptor?
    
    /// Task completion notification to notify about the end of decryption process.
    override var taskCompleteNotification: Notification.Name {
        LCPDownloadTaskCompleteNotification
    }
    
    /// Audio file status. LCP audiobooks contain all encrypted audio files inside, this method returns status of decrypted versions of these files.
    /// - Parameter task: `LCPDownloadTask` containing internal url (e.g., `media/sound.mp3`) for decryption.
    /// - Returns: Status of the file, .unknown in case of an error, .missing if the file needs decryption, .saved when accessing an already decrypted file.
    override func assetFileStatus(_ task: DownloadTask?) -> AssetResult? {
        if let delegate = decryptionDelegate, let task = task as? LCPDownloadTask, let decryptedUrls = task.decryptedUrls {
            var savedUrls = [URL]()
            var missingUrls = [URL]()
            
            for (index, decryptedUrl) in decryptedUrls.enumerated() {
                // Return file URL if it already decrypted
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
            
            guard missingUrls.count == 0  else {
                return .missing(missingUrls)
            }
            
            return .saved(savedUrls)
        } else {
            return .unknown
        }
    }
    
    /// Audiobook player
    /// - Parameters:
    ///   - tableOfContents: Audiobook player's table of contents.
    ///   - decryptor: LCP DRM decryptor.
    init(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) {
        self.decryptionDelegate = decryptor
        super.init(tableOfContents: tableOfContents)
    }
    
    required init(tableOfContents: AudiobookTableOfContents) {
        super.init(tableOfContents: tableOfContents)
    }
}
