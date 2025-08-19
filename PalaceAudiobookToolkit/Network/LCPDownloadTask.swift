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
    /// For LCP we decrypt locally into cache; start at 0 and advance as files are decrypted
    var downloadProgress: Float = 0.0
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
        self.downloadProgress = 0.0
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
        // For LCP, we need to trigger the decryption process
        // This will be handled by DefaultAudiobookNetworkService.startLCPDecryption()
        // which calls the decryptor.decrypt() method for each file
        ATLog(.debug, "🎵 [LCPDownloadTask] Starting LCP decryption for \(key)")
        // The actual decryption is handled by the AudiobookNetworkService
    }
    
    func assetFileStatus() -> AssetResult {
        if let decrypted = decryptedUrls, !decrypted.isEmpty {
            let fm = FileManager.default
            // Check that files exist AND are valid audio files (not encrypted content)
            let validFiles = decrypted.filter { url in
                guard fm.fileExists(atPath: url.path) else { return false }
                do {
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    
                    // Require files to be reasonably sized
                    guard fileSize > 10000 else { return false } // At least 10KB
                    
                    // Check if the file starts with valid audio headers
                    let fileHandle = try FileHandle(forReadingFrom: url)
                    defer { fileHandle.closeFile() }
                    
                    let headerData = fileHandle.readData(ofLength: 16)
                    guard headerData.count >= 4 else { return false }
                    
                    // Check for common audio file signatures
                    let header = headerData.prefix(4)
                    
                    // MP3: ID3 tag or MPEG audio frame
                    if header.starts(with: Data([0x49, 0x44, 0x33])) || // ID3
                       header.starts(with: Data([0xFF, 0xFB])) ||        // MPEG Layer 3
                       header.starts(with: Data([0xFF, 0xFA])) ||        // MPEG Layer 3
                       header.starts(with: Data([0xFF, 0xF3])) ||        // MPEG Layer 3
                       header.starts(with: Data([0xFF, 0xF2])) {         // MPEG Layer 3
                        return true
                    }
                    
                    // M4A/AAC: ftyp header
                    if headerData.count >= 8 {
                        let ftypOffset = headerData.range(of: Data([0x66, 0x74, 0x79, 0x70]))
                        if ftypOffset != nil {
                            return true
                        }
                    }
                    
                    return false
                } catch {
                    return false
                }
            }
            
            if validFiles.count == decrypted.count {
                return .saved(decrypted)
            }
        }
        return .missing([])
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
