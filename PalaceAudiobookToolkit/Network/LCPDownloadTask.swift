//
//  LCPDownloadTask.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 19.11.2020.
//  Copyright © 2020 Dean Silfen. All rights reserved.
//

import Combine
import Foundation

let LCPDownloadTaskCompleteNotification = NSNotification.Name(rawValue: "LCPDownloadTaskCompleteNotification")

// MARK: - LCPDownloadTask

/**
 This file is created for protocol conformance.
 All audio files are embedded into LCP-protected audiobook file.
 */
/// - Note: `@unchecked Sendable` is justified by construction rather than by
///   assertion: every stored property is either a `let` (`key`, `urls`,
///   `decryptedUrls`, `urlMediaType`, `statePublisher`) or lock-guarded
///   (`_downloadProgress`). There is no unsynchronized mutable state left, so
///   the type may cross isolation domains — which it does, being read by the UI
///   while the decryption path drives it. Adding a plain `var` stored property
///   here would invalidate that reasoning.
final class LCPDownloadTask: DownloadTask, @unchecked Sendable {
  let statePublisher = PassthroughSubject<DownloadTaskState, Never>()
  
  /// For LCP we decrypt locally into cache; lazily initialized based on file status.
  ///
  /// Lock-guarded: written from the decryption/progress path and read by the UI
  /// for the progress bar, so plain stored access was a data race on every read
  /// as well as every write — the getter itself mutates on first use.
  private let _downloadProgress = LockIsolated<Float?>(nil)
  var downloadProgress: Float {
    get {
      if let cached = _downloadProgress.value {
        return cached
      }
      // Resolve the initial value OUTSIDE the lock: assetFileStatus() touches
      // the file system, which must not run while the lock is held.
      let initial: Float
      switch assetFileStatus() {
      case .saved:
        initial = 1.0
      case .missing, .unknown:
        initial = 0.0
      }
      return _downloadProgress.withValue { stored in
        // Another thread may have resolved it while we were off the lock; its
        // value wins so all callers observe the same progress.
        if let existing = stored {
          return existing
        }
        stored = initial
        return initial
      }
    }
    set {
      let didChange = _downloadProgress.withValue { stored -> Bool in
        let oldValue = stored
        stored = newValue
        return oldValue != newValue
      }
      // Only publish if value changed
      if didChange {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.statePublisher.send(.progress(newValue))
        }
      }
    }
  }
  
  let key: String
  /// URL of a file inside the audiobook archive (e.g., `media/sound.mp3`)
  let urls: [URL]
  /// URL for decrypted audio file. Assigned once during `init` and only read
  /// afterwards (by `AudiobookNetworkService`, `LCPTrack` and `delete()`), so
  /// it is immutable — which is what lets this type claim `Sendable` honestly.
  let decryptedUrls: [URL]?
  let urlMediaType: TrackMediaType

  var needsRetry: Bool { false }

  init(key: String, urls: [URL]?, mediaType: TrackMediaType) {
    self.key = key
    self.urls = urls ?? []
    urlMediaType = mediaType
    decryptedUrls = self.urls.compactMap { Self.decryptedFileURL(for: $0) }
    // Note: downloadProgress is lazily initialized based on assetFileStatus()
  }

  /// URL for decryption delegate to store decrypted file.
  ///
  /// Static because it runs while `decryptedUrls` is still being initialized,
  /// and `let` storage forbids touching `self` until every member is assigned.
  ///
  /// The two failure paths previously also emitted `statePublisher.send(.error(nil))`.
  /// Those sends were unreachable as events: this is only ever called from
  /// `init`, so no subscriber can exist yet and `PassthroughSubject` does not
  /// replay. The diagnostics that carried the real information — the `ATLog`
  /// lines — are retained.
  ///
  /// - Parameter url: Internal file URL (e.g., `media/sound.mp3`).
  /// - Returns: `URL` to store decrypted file.
  private static func decryptedFileURL(for url: URL) -> URL? {
    guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      ATLog(.error, "Could not find caches directory.")
      return nil
    }
    guard let hashedUrl = url.path.sha256?.hexString else {
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
        guard fm.fileExists(atPath: url.path) else {
          return false
        }
        do {
          let attributes = try fm.attributesOfItem(atPath: url.path)
          let fileSize = attributes[.size] as? Int64 ?? 0

          // Require files to be reasonably sized
          guard fileSize > 10000 else {
            return false
          } // At least 10KB

          // Check if the file starts with valid audio headers
          let fileHandle = try FileHandle(forReadingFrom: url)
          defer { fileHandle.closeFile() }

          let headerData = fileHandle.readData(ofLength: 16)
          guard headerData.count >= 4 else {
            return false
          }

          // Check for common audio file signatures
          let header = headerData.prefix(4)

          // MP3: ID3 tag or MPEG audio frame
          if header.starts(with: Data([0x49, 0x44, 0x33])) || // ID3
            header.starts(with: Data([0xFF, 0xFB])) || // MPEG Layer 3
            header.starts(with: Data([0xFF, 0xFA])) || // MPEG Layer 3
            header.starts(with: Data([0xFF, 0xF3])) || // MPEG Layer 3
            header.starts(with: Data([0xFF, 0xF2]))
          { // MPEG Layer 3
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
