//
//  LCPDownloadTask.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 19.11.2020.
//  Copyright © 2020 Dean Silfen. All rights reserved.
//

import Foundation
import Combine

let LCPDownloadTaskCompleteNotification = NSNotification.Name(rawValue: "LCPDownloadTaskCompleteNotification")

/**
 This file is created for protocol conformance.
 All audio files are embedded into LCP-protected audiobook file.
 */
final class LCPDownloadTask: DownloadTask {
    var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    /// All encrypted files are included in the audiobook, download progress is 1.0
    var downloadProgress: Float = 1.0
    let key: String
    /// URL of a file inside the audiobook archive (e.g., `media/sound.mp3`)
    let urls: [URL]
    /// URL for decrypted audio file
    var decryptedUrls: [URL]? = []
    let urlMediaType: TrackMediaType

    var needsRetry: Bool { false }
    
    init(key: String, urls: [URL]?, mediaType: TrackMediaType) {
        self.key = key
        self.urls = urls ?? []
        self.urlMediaType = mediaType
        self.decryptedUrls = self.urls.compactMap { decryptedFileURL(for:$0) }
        self.statePublisher.send(.completed)
    }

    /// URL for decryption delegate to store decrypted file.
    /// - Parameter url: Internal file URL (e.g., `media/sound.mp3`).
    /// - Returns: `URL` to store decrypted file.
    private func decryptedFileURL(for url: URL) -> URL? {
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            self.statePublisher.send(.error(nil))
            ATLog(.error, "Could not find caches directory.")
            return nil
        }
        guard let hashedUrl = url.path.sha256?.hexString else {
            self.statePublisher.send(.error(nil))
            ATLog(.error, "Could not create a valid hash from download task ID.")
            return nil
        }
        return cacheDirectory.appendingPathComponent(hashedUrl).appendingPathExtension(url.pathExtension)
    }
    
    func fetch() {
        // No need to download files.
    }
    
    func assetFileStatus() -> AssetResult {
        .unknown
    }
    
    /// Delete decrypted file
    func delete() {
        let fileManager = FileManager.default
        decryptedUrls?.forEach {
            guard fileManager.fileExists(atPath: $0.path) else {
                return
            }
            
            do {
                try fileManager.removeItem(at: $0)
                self.statePublisher.send(.deleted)
            } catch {
                self.statePublisher.send(.error(error))
                ATLog(.warn, "Could not delete decrypted file.", error: error)
            }
        }
    }
}
