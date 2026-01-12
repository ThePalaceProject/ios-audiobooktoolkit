//
//  DownloadPersistenceStore.swift
//  PalaceAudiobookToolkit
//
//  Created for Audiobook Reliability Fix
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Persists download state to disk so downloads can be resumed after app restart.
/// Stores information about active downloads, completed downloads, and partially
/// downloaded files.
public final class DownloadPersistenceStore {
  
  // MARK: - Singleton
  
  public static let shared = DownloadPersistenceStore()
  
  // MARK: - Types
  
  /// Represents a persisted download's state
  public struct PersistedDownload: Codable, Equatable {
    public let bookID: String
    public let trackKey: String
    public let remoteURL: URL
    public let localFileURL: URL
    public let totalBytes: Int64
    public var downloadedBytes: Int64
    public var state: DownloadState
    public let createdAt: Date
    public var updatedAt: Date
    
    public enum DownloadState: String, Codable {
      case pending
      case inProgress
      case paused
      case completed
      case failed
    }
    
    public var progress: Float {
      guard totalBytes > 0 else { return 0 }
      return Float(downloadedBytes) / Float(totalBytes)
    }
    
    public var isComplete: Bool {
      state == .completed && downloadedBytes >= totalBytes
    }
  }
  
  /// All downloads for a specific audiobook
  public struct BookDownloads: Codable {
    public let bookID: String
    public var tracks: [String: PersistedDownload]
    public var lastAccessedAt: Date
    
    public var totalTracks: Int {
      tracks.count
    }
    
    public var completedTracks: Int {
      tracks.values.filter { $0.isComplete }.count
    }
    
    public var overallProgress: Float {
      guard !tracks.isEmpty else { return 0 }
      let totalProgress = tracks.values.reduce(0.0) { $0 + $1.progress }
      return totalProgress / Float(tracks.count)
    }
  }
  
  // MARK: - Properties
  
  private let fileManager = FileManager.default
  private let queue = DispatchQueue(label: "com.palace.downloadPersistenceStore", attributes: .concurrent)
  private var cache: [String: BookDownloads] = [:]
  
  private var storeURL: URL? {
    guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = appSupport.appendingPathComponent("Audiobooks", isDirectory: true)
    return dir.appendingPathComponent("download_persistence.json")
  }
  
  /// Directory for storing resume data files
  private var resumeDataDirectory: URL? {
    guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    return appSupport.appendingPathComponent("Audiobooks/ResumeData", isDirectory: true)
  }
  
  // MARK: - Initialization
  
  private init() {
    loadFromDisk()
    
    // Set up low memory warning handling
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  @objc private func handleMemoryWarning() {
    // Save to disk and clear memory cache
    saveToDisk()
  }
  
  // MARK: - Public API
  
  /// Registers a new download to be tracked.
  public func registerDownload(
    bookID: String,
    trackKey: String,
    remoteURL: URL,
    localFileURL: URL,
    totalBytes: Int64
  ) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      let download = PersistedDownload(
        bookID: bookID,
        trackKey: trackKey,
        remoteURL: remoteURL,
        localFileURL: localFileURL,
        totalBytes: totalBytes,
        downloadedBytes: 0,
        state: .pending,
        createdAt: Date(),
        updatedAt: Date()
      )
      
      if var bookDownloads = self.cache[bookID] {
        bookDownloads.tracks[trackKey] = download
        bookDownloads.lastAccessedAt = Date()
        self.cache[bookID] = bookDownloads
      } else {
        let bookDownloads = BookDownloads(
          bookID: bookID,
          tracks: [trackKey: download],
          lastAccessedAt: Date()
        )
        self.cache[bookID] = bookDownloads
      }
      
      self.saveToDisk()
      ATLog(.debug, "DownloadPersistenceStore: Registered download for \(bookID)/\(trackKey)")
    }
  }
  
  /// Updates the progress of a download.
  public func updateProgress(
    bookID: String,
    trackKey: String,
    downloadedBytes: Int64,
    state: PersistedDownload.DownloadState = .inProgress
  ) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var bookDownloads = self.cache[bookID],
            var download = bookDownloads.tracks[trackKey] else {
        return
      }
      
      download.downloadedBytes = downloadedBytes
      download.state = state
      download.updatedAt = Date()
      bookDownloads.tracks[trackKey] = download
      bookDownloads.lastAccessedAt = Date()
      self.cache[bookID] = bookDownloads
      
      // Only save to disk periodically to avoid excessive I/O
      // The actual bytes are saved, so we can recover on crash
      if Int(download.progress * 100) % 10 == 0 {
        self.saveToDisk()
      }
    }
  }
  
  /// Marks a download as completed.
  public func markCompleted(bookID: String, trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var bookDownloads = self.cache[bookID],
            var download = bookDownloads.tracks[trackKey] else {
        return
      }
      
      download.state = .completed
      download.downloadedBytes = download.totalBytes
      download.updatedAt = Date()
      bookDownloads.tracks[trackKey] = download
      bookDownloads.lastAccessedAt = Date()
      self.cache[bookID] = bookDownloads
      
      self.saveToDisk()
      ATLog(.info, "DownloadPersistenceStore: Marked download complete for \(bookID)/\(trackKey)")
    }
  }
  
  /// Marks a download as failed.
  public func markFailed(bookID: String, trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var bookDownloads = self.cache[bookID],
            var download = bookDownloads.tracks[trackKey] else {
        return
      }
      
      download.state = .failed
      download.updatedAt = Date()
      bookDownloads.tracks[trackKey] = download
      self.cache[bookID] = bookDownloads
      
      self.saveToDisk()
      ATLog(.warn, "DownloadPersistenceStore: Marked download failed for \(bookID)/\(trackKey)")
    }
  }
  
  /// Gets the persisted state for a specific download.
  public func getDownload(bookID: String, trackKey: String) -> PersistedDownload? {
    queue.sync {
      return cache[bookID]?.tracks[trackKey]
    }
  }
  
  /// Gets all downloads for a specific book.
  public func getBookDownloads(bookID: String) -> BookDownloads? {
    queue.sync {
      return cache[bookID]
    }
  }
  
  /// Gets all pending/incomplete downloads for a book.
  public func getIncompleteDownloads(bookID: String) -> [PersistedDownload] {
    queue.sync {
      guard let bookDownloads = cache[bookID] else {
        return []
      }
      return bookDownloads.tracks.values.filter { !$0.isComplete }
    }
  }
  
  /// Removes tracking for a specific download.
  public func removeDownload(bookID: String, trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var bookDownloads = self.cache[bookID] else {
        return
      }
      
      bookDownloads.tracks.removeValue(forKey: trackKey)
      
      if bookDownloads.tracks.isEmpty {
        self.cache.removeValue(forKey: bookID)
      } else {
        self.cache[bookID] = bookDownloads
      }
      
      self.saveToDisk()
      ATLog(.debug, "DownloadPersistenceStore: Removed download for \(bookID)/\(trackKey)")
    }
  }
  
  /// Removes all tracking for a book.
  public func removeAllDownloads(forBookID bookID: String) {
    queue.async(flags: .barrier) { [weak self] in
      self?.cache.removeValue(forKey: bookID)
      self?.saveToDisk()
      ATLog(.info, "DownloadPersistenceStore: Removed all downloads for book: \(bookID)")
    }
  }
  
  /// Clears all persisted data.
  public func clearAll() {
    queue.async(flags: .barrier) { [weak self] in
      self?.cache.removeAll()
      if let url = self?.storeURL {
        try? FileManager.default.removeItem(at: url)
      }
      ATLog(.info, "DownloadPersistenceStore: Cleared all persisted downloads")
    }
  }
  
  /// Forces an immediate save to disk.
  public func forceSave() {
    queue.async(flags: .barrier) { [weak self] in
      self?.saveToDisk()
    }
  }
  
  // MARK: - Resume Data Management
  
  /// Saves resume data for a download that was interrupted.
  /// This allows the download to continue from where it left off.
  ///
  /// - Parameters:
  ///   - resumeData: The resume data from URLSessionDownloadTask
  ///   - trackKey: Unique identifier for the track
  public func saveResumeData(_ resumeData: Data, forTrackKey trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            let directory = self.resumeDataDirectory else {
        ATLog(.error, "DownloadPersistenceStore: Cannot get resume data directory")
        return
      }
      
      // Create directory if needed
      if !self.fileManager.fileExists(atPath: directory.path) {
        do {
          try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
          ATLog(.error, "DownloadPersistenceStore: Failed to create resume data directory: \(error)")
          return
        }
      }
      
      // Save resume data to file (use sha256 hash of track key for filename)
      guard let hash = trackKey.sha256?.hexString else {
        ATLog(.error, "DownloadPersistenceStore: Failed to hash track key")
        return
      }
      let fileURL = directory.appendingPathComponent("\(hash).resumedata")
      do {
        try resumeData.write(to: fileURL, options: .atomic)
        ATLog(.info, "DownloadPersistenceStore: Saved resume data for track: \(trackKey) (\(resumeData.count) bytes)")
      } catch {
        ATLog(.error, "DownloadPersistenceStore: Failed to save resume data: \(error)")
      }
    }
  }
  
  /// Retrieves saved resume data for a track.
  ///
  /// - Parameter trackKey: Unique identifier for the track
  /// - Returns: Resume data if available, nil otherwise
  public func getResumeData(forTrackKey trackKey: String) -> Data? {
    return queue.sync {
      guard let directory = resumeDataDirectory else {
        return nil
      }
      
      guard let hash = trackKey.sha256?.hexString else {
        return nil
      }
      let fileURL = directory.appendingPathComponent("\(hash).resumedata")
      
      guard fileManager.fileExists(atPath: fileURL.path) else {
        return nil
      }
      
      do {
        let data = try Data(contentsOf: fileURL)
        ATLog(.info, "DownloadPersistenceStore: Retrieved resume data for track: \(trackKey) (\(data.count) bytes)")
        return data
      } catch {
        ATLog(.error, "DownloadPersistenceStore: Failed to read resume data: \(error)")
        return nil
      }
    }
  }
  
  /// Removes saved resume data for a track (call after successful download).
  ///
  /// - Parameter trackKey: Unique identifier for the track
  public func removeResumeData(forTrackKey trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            let directory = self.resumeDataDirectory else {
        return
      }
      
      guard let hash = trackKey.sha256?.hexString else {
        return
      }
      let fileURL = directory.appendingPathComponent("\(hash).resumedata")
      
      if self.fileManager.fileExists(atPath: fileURL.path) {
        do {
          try self.fileManager.removeItem(at: fileURL)
          ATLog(.debug, "DownloadPersistenceStore: Removed resume data for track: \(trackKey)")
        } catch {
          ATLog(.warn, "DownloadPersistenceStore: Failed to remove resume data: \(error)")
        }
      }
    }
  }
  
  /// Clears all resume data files.
  public func clearAllResumeData() {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            let directory = self.resumeDataDirectory else {
        return
      }
      
      if self.fileManager.fileExists(atPath: directory.path) {
        do {
          try self.fileManager.removeItem(at: directory)
          ATLog(.info, "DownloadPersistenceStore: Cleared all resume data")
        } catch {
          ATLog(.error, "DownloadPersistenceStore: Failed to clear resume data: \(error)")
        }
      }
    }
  }
  
  // MARK: - Persistence
  
  private func loadFromDisk() {
    guard let url = storeURL,
          fileManager.fileExists(atPath: url.path) else {
      ATLog(.debug, "DownloadPersistenceStore: No persisted data found")
      return
    }
    
    do {
      let data = try Data(contentsOf: url)
      let decoded = try JSONDecoder().decode([String: BookDownloads].self, from: data)
      cache = decoded
      ATLog(.info, "DownloadPersistenceStore: Loaded \(cache.count) books from disk")
    } catch {
      ATLog(.error, "DownloadPersistenceStore: Failed to load from disk: \(error.localizedDescription)")
    }
  }
  
  private func saveToDisk() {
    guard let url = storeURL else {
      ATLog(.error, "DownloadPersistenceStore: Cannot get store URL")
      return
    }
    
    do {
      let directory = url.deletingLastPathComponent()
      if !fileManager.fileExists(atPath: directory.path) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      
      let data = try JSONEncoder().encode(cache)
      try data.write(to: url, options: .atomic)
    } catch {
      ATLog(.error, "DownloadPersistenceStore: Failed to save to disk: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Recovery
  
  /// Validates persisted downloads against actual files on disk.
  /// Returns downloads where the file exists but wasn't marked complete.
  public func validateAndRecoverDownloads(forBookID bookID: String) -> [PersistedDownload] {
    queue.sync {
      guard let bookDownloads = cache[bookID] else {
        return []
      }
      
      var recovered: [PersistedDownload] = []
      
      for (_, download) in bookDownloads.tracks {
        let fileExists = fileManager.fileExists(atPath: download.localFileURL.path)
        
        if fileExists && download.state != .completed {
          // File exists but wasn't marked complete - may have been
          // downloaded in background after app was terminated
          recovered.append(download)
          ATLog(.info, "DownloadPersistenceStore: Found completed file for \(download.trackKey)")
        } else if !fileExists && download.state == .completed {
          // Was marked complete but file is missing (purged by iOS?)
          ATLog(.warn, "DownloadPersistenceStore: File missing for completed download: \(download.trackKey)")
        }
      }
      
      return recovered
    }
  }
}
