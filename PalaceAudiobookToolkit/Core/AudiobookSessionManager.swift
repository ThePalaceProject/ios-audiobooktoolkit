//
//  AudiobookSessionManager.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Singleton manager for audiobook download sessions.
/// Persists across audiobook opens to maintain download state and handle
/// background session reconnection.
public final class AudiobookSessionManager {
  
  // MARK: - Singleton
  
  public static let shared = AudiobookSessionManager()
  
  // MARK: - Properties
  
  /// Completion handlers waiting to be called for background sessions
  private var backgroundCompletionHandlers: [String: () -> Void] = [:]
  
  /// Reconnected URLSessions that must be kept alive
  private var reconnectedSessions: [String: URLSession] = [:]
  
  /// Active download tasks mapped by session identifier
  private var activeDownloads: [String: DownloadInfo] = [:]
  
  /// Publisher for download state changes
  public let downloadStatePublisher = PassthroughSubject<AudiobookDownloadEvent, Never>()
  
  /// Thread-safe access queue
  private let queue = DispatchQueue(label: "com.palace.audiobookSessionManager", attributes: .concurrent)
  
  // MARK: - Types
  
  /// Information about an active download
  public struct DownloadInfo {
    public let sessionIdentifier: String
    public let bookID: String
    public let trackKey: String
    public let originalURL: URL
    public let localDestination: URL
    public var progress: Float
    public var state: DownloadState
    
    public enum DownloadState: String, Codable {
      case downloading
      case completed
      case failed
      case paused
    }
  }
  
  /// Events published for download state changes
  public enum AudiobookDownloadEvent {
    case downloadCompleted(sessionIdentifier: String, fileURL: URL)
    case downloadFailed(sessionIdentifier: String, error: Error)
    case downloadProgress(sessionIdentifier: String, progress: Float)
    case sessionReconnected(sessionIdentifier: String)
  }
  
  // MARK: - Initialization
  
  private init() {
    ATLog(.debug, "AudiobookSessionManager: Initialized")
    loadPersistedState()
  }
  
  // MARK: - Background Session Management
  
  /// Registers a completion handler for a background session.
  /// iOS requires this handler to be called when all events for the session have been processed.
  ///
  /// - Parameters:
  ///   - handler: The completion handler provided by iOS
  ///   - identifier: The background session identifier
  public func registerBackgroundCompletionHandler(_ handler: @escaping () -> Void, forSessionIdentifier identifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      self?.backgroundCompletionHandlers[identifier] = handler
      ATLog(.debug, "AudiobookSessionManager: Registered completion handler for session: \(identifier)")
    }
  }
  
  /// Calls and removes the completion handler for a background session.
  /// This must be called on the main thread as required by iOS.
  ///
  /// - Parameter identifier: The background session identifier
  public func callCompletionHandler(forSessionIdentifier identifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let handler = self?.backgroundCompletionHandlers.removeValue(forKey: identifier) else {
        ATLog(.warn, "AudiobookSessionManager: No completion handler found for session: \(identifier)")
        return
      }
      
      DispatchQueue.main.async {
        ATLog(.info, "AudiobookSessionManager: Calling completion handler for session: \(identifier)")
        handler()
      }
      
      // Clean up the reconnected session
      self?.reconnectedSessions.removeValue(forKey: identifier)
    }
  }
  
  /// Stores a reconnected URLSession to prevent it from being deallocated.
  ///
  /// - Parameters:
  ///   - session: The reconnected URLSession
  ///   - identifier: The session identifier
  public func storeReconnectedSession(_ session: URLSession, forIdentifier identifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      self?.reconnectedSessions[identifier] = session
      ATLog(.debug, "AudiobookSessionManager: Stored reconnected session: \(identifier)")
    }
    
    downloadStatePublisher.send(.sessionReconnected(sessionIdentifier: identifier))
  }
  
  // MARK: - Download Event Handling
  
  /// Handles a background download completion.
  ///
  /// - Parameters:
  ///   - sessionIdentifier: The session identifier
  ///   - downloadedFileURL: The temporary location of the downloaded file
  ///   - originalURL: The original remote URL that was downloaded
  public func handleBackgroundDownloadCompletion(
    sessionIdentifier: String,
    downloadedFileURL: URL,
    originalURL: URL
  ) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      // Find the download info for this session
      if var downloadInfo = self.activeDownloads[sessionIdentifier] {
        // Move the file to its final destination
        let destinationURL = downloadInfo.localDestination
        
        do {
          let fileManager = FileManager.default
          
          // Create directory if needed
          let directory = destinationURL.deletingLastPathComponent()
          if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
          }
          
          // Remove existing file if present
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
          }
          
          // Move the downloaded file
          try fileManager.moveItem(at: downloadedFileURL, to: destinationURL)
          
          downloadInfo.state = .completed
          downloadInfo.progress = 1.0
          self.activeDownloads[sessionIdentifier] = downloadInfo
          
          ATLog(.info, "AudiobookSessionManager: Download completed and moved to: \(destinationURL.path)")
          
          DispatchQueue.main.async {
            self.downloadStatePublisher.send(.downloadCompleted(sessionIdentifier: sessionIdentifier, fileURL: destinationURL))
          }
          
          // Persist the updated state
          self.persistState()
          
        } catch {
          ATLog(.error, "AudiobookSessionManager: Failed to move downloaded file: \(error.localizedDescription)")
          downloadInfo.state = .failed
          self.activeDownloads[sessionIdentifier] = downloadInfo
          
          DispatchQueue.main.async {
            self.downloadStatePublisher.send(.downloadFailed(sessionIdentifier: sessionIdentifier, error: error))
          }
        }
      } else {
        ATLog(.warn, "AudiobookSessionManager: No download info found for session: \(sessionIdentifier)")
        
        // Still notify about the completion
        DispatchQueue.main.async {
          self.downloadStatePublisher.send(.downloadCompleted(sessionIdentifier: sessionIdentifier, fileURL: downloadedFileURL))
        }
      }
    }
  }
  
  /// Handles a background download error.
  ///
  /// - Parameters:
  ///   - sessionIdentifier: The session identifier
  ///   - error: The error that occurred
  public func handleBackgroundDownloadError(sessionIdentifier: String, error: Error) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      if var downloadInfo = self.activeDownloads[sessionIdentifier] {
        downloadInfo.state = .failed
        self.activeDownloads[sessionIdentifier] = downloadInfo
        self.persistState()
      }
      
      ATLog(.error, "AudiobookSessionManager: Download failed for session \(sessionIdentifier): \(error.localizedDescription)")
      
      DispatchQueue.main.async {
        self.downloadStatePublisher.send(.downloadFailed(sessionIdentifier: sessionIdentifier, error: error))
      }
    }
  }
  
  // MARK: - Active Download Management
  
  /// Registers an active download.
  ///
  /// - Parameters:
  ///   - sessionIdentifier: The unique session identifier
  ///   - bookID: The audiobook identifier
  ///   - trackKey: The track key
  ///   - originalURL: The remote URL being downloaded
  ///   - localDestination: Where the file should be saved
  public func registerActiveDownload(
    sessionIdentifier: String,
    bookID: String,
    trackKey: String,
    originalURL: URL,
    localDestination: URL
  ) {
    queue.async(flags: .barrier) { [weak self] in
      let downloadInfo = DownloadInfo(
        sessionIdentifier: sessionIdentifier,
        bookID: bookID,
        trackKey: trackKey,
        originalURL: originalURL,
        localDestination: localDestination,
        progress: 0.0,
        state: .downloading
      )
      self?.activeDownloads[sessionIdentifier] = downloadInfo
      self?.persistState()
      
      ATLog(.debug, "AudiobookSessionManager: Registered active download for session: \(sessionIdentifier)")
    }
  }
  
  /// Updates the progress of an active download.
  ///
  /// - Parameters:
  ///   - sessionIdentifier: The session identifier
  ///   - progress: The download progress (0.0 to 1.0)
  public func updateDownloadProgress(sessionIdentifier: String, progress: Float) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      if var downloadInfo = self.activeDownloads[sessionIdentifier] {
        downloadInfo.progress = progress
        self.activeDownloads[sessionIdentifier] = downloadInfo
      }
      
      DispatchQueue.main.async {
        self.downloadStatePublisher.send(.downloadProgress(sessionIdentifier: sessionIdentifier, progress: progress))
      }
    }
  }
  
  /// Removes a download from active tracking.
  ///
  /// - Parameter sessionIdentifier: The session identifier
  public func removeActiveDownload(sessionIdentifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      self?.activeDownloads.removeValue(forKey: sessionIdentifier)
      self?.persistState()
      ATLog(.debug, "AudiobookSessionManager: Removed active download for session: \(sessionIdentifier)")
    }
  }
  
  /// Gets all active downloads for a specific book.
  ///
  /// - Parameter bookID: The audiobook identifier
  /// - Returns: Array of download info for the book
  public func activeDownloads(forBookID bookID: String) -> [DownloadInfo] {
    queue.sync {
      return activeDownloads.values.filter { $0.bookID == bookID }
    }
  }
  
  /// Checks if there's an active download for a specific session.
  ///
  /// - Parameter sessionIdentifier: The session identifier
  /// - Returns: The download info if found
  public func downloadInfo(forSessionIdentifier sessionIdentifier: String) -> DownloadInfo? {
    queue.sync {
      return activeDownloads[sessionIdentifier]
    }
  }
  
  // MARK: - Persistence
  
  /// File URL for persisting download state
  private var persistenceURL: URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let audiobookDir = appSupport.appendingPathComponent("Audiobooks", isDirectory: true)
    return audiobookDir.appendingPathComponent("download_state.json")
  }
  
  /// Persists the current download state to disk.
  private func persistState() {
    guard let url = persistenceURL else {
      ATLog(.error, "AudiobookSessionManager: Cannot get persistence URL")
      return
    }
    
    do {
      let fileManager = FileManager.default
      let directory = url.deletingLastPathComponent()
      if !fileManager.fileExists(atPath: directory.path) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      
      // Convert to codable format
      let persistableDownloads = activeDownloads.mapValues { info in
        PersistableDownloadInfo(
          sessionIdentifier: info.sessionIdentifier,
          bookID: info.bookID,
          trackKey: info.trackKey,
          originalURL: info.originalURL.absoluteString,
          localDestination: info.localDestination.absoluteString,
          progress: info.progress,
          state: info.state.rawValue
        )
      }
      
      let data = try JSONEncoder().encode(persistableDownloads)
      try data.write(to: url)
      
      ATLog(.debug, "AudiobookSessionManager: Persisted \(activeDownloads.count) downloads to disk")
    } catch {
      ATLog(.error, "AudiobookSessionManager: Failed to persist state: \(error.localizedDescription)")
    }
  }
  
  /// Loads persisted download state from disk.
  private func loadPersistedState() {
    guard let url = persistenceURL else {
      return
    }
    
    do {
      let data = try Data(contentsOf: url)
      let persistedDownloads = try JSONDecoder().decode([String: PersistableDownloadInfo].self, from: data)
      
      // Convert back to DownloadInfo
      activeDownloads = persistedDownloads.compactMapValues { persisted in
        guard let originalURL = URL(string: persisted.originalURL),
              let localDestination = URL(string: persisted.localDestination),
              let state = DownloadInfo.DownloadState(rawValue: persisted.state) else {
          return nil
        }
        
        return DownloadInfo(
          sessionIdentifier: persisted.sessionIdentifier,
          bookID: persisted.bookID,
          trackKey: persisted.trackKey,
          originalURL: originalURL,
          localDestination: localDestination,
          progress: persisted.progress,
          state: state
        )
      }
      
      ATLog(.info, "AudiobookSessionManager: Loaded \(activeDownloads.count) persisted downloads")
    } catch {
      ATLog(.debug, "AudiobookSessionManager: No persisted state found or failed to load: \(error.localizedDescription)")
    }
  }
  
  /// Clears all persisted state (for testing or reset).
  public func clearAllState() {
    queue.async(flags: .barrier) { [weak self] in
      self?.activeDownloads.removeAll()
      self?.reconnectedSessions.removeAll()
      self?.backgroundCompletionHandlers.removeAll()
      
      if let url = self?.persistenceURL {
        try? FileManager.default.removeItem(at: url)
      }
      
      ATLog(.info, "AudiobookSessionManager: Cleared all state")
    }
  }
  
  /// Migrates all audiobook downloads from Caches to Application Support.
  /// This prevents iOS from purging downloaded audiobook files.
  /// Call this once during app startup.
  public static func migrateDownloadsFromCaches() {
    OpenAccessDownloadTask.migrateFromCachesIfNeeded()
    OverdriveDownloadTask.migrateFromCachesIfNeeded()
    ATLog(.info, "AudiobookSessionManager: Completed download migration check")
  }
}

// MARK: - Persistence Codable Types

private struct PersistableDownloadInfo: Codable {
  let sessionIdentifier: String
  let bookID: String
  let trackKey: String
  let originalURL: String
  let localDestination: String
  let progress: Float
  let state: String
}
