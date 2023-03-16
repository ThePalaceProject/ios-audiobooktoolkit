//
//  LCPPlayer.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 19.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import AVFoundation

class LCPPlayer: OpenAccessPlayer {

    /// DRMDecryptor passed from SimplyE to process encrypted audio files.
    var decryptionDelegate: DRMDecryptor?
    
    /// Task completion notification to notify about the end of decryption process.
    override var taskCompleteNotification: Notification.Name {
        LCPDownloadTaskCompleteNotification
    }
    
    /// Audio file status. LCP audiobooks contain all encrypted audio files inside, this method returns status of decrypted versions of these files.
    /// - Parameter task: `LCPDownloadTask` containing internal url (e.g., `media/sound.mp3`) for decryption.
    /// - Returns: Status of the file, .unknown in case of an error, .missing if the file needs decryption, .saved when accessing an already decrypted file.
    override func assetFileStatus(_ task: DownloadTask) -> AssetResult? {
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
                        // taskCompleteNotification notifies the player to call `play` function again.
                        NotificationCenter.default.post(name: self.taskCompleteNotification, object: task)
                        
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
    
    @available(*, deprecated, message: "Use init(cursor: Cursor<SpineElement>, audiobookID: String, decryptor: DRMDecryptor?) instead")
    required convenience init(cursor: Cursor<SpineElement>, audiobookID: String, drmOk: Bool) {
        self.init(cursor: cursor, audiobookID: audiobookID, decryptor: nil)
    }
    
    /// Audiobook player
    /// - Parameters:
    ///   - cursor: Player cursor for the audiobook spine.
    ///   - audiobookID: Audiobook identifier.
    ///   - decryptor: LCP DRM decryptor.
    init(cursor: Cursor<SpineElement>, audiobookID: String, decryptor: DRMDecryptor?) {
        self.decryptionDelegate = decryptor
        super.init(cursor: cursor, audiobookID: audiobookID, drmOk: true)
    }
}
