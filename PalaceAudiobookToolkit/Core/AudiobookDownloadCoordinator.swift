//
//  AudiobookDownloadCoordinator.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Singleton manager for audiobook download sessions.
/// Persists across audiobook opens to maintain download state and handle
/// background session reconnection.
public final class AudiobookDownloadCoordinator {
  
  // MARK: - Singleton
  
  public static let shared = AudiobookDownloadCoordinator()
  
  // MARK: - Properties
  
  /// Completion handlers waiting to be called for background sessions
  private var backgroundCompletionHandlers: [String: () -> Void] = [:]
  
  /// Reconnected URLSessions that must be kept alive
  private var reconnectedSessions: [String: URLSession] = [:]

  /// Background `URLSession`s owned by the coordinator for the app's lifetime,
  /// keyed by background-session identifier. F2: exactly ONE live background
  /// session per identifier. The per-track download tasks (`OpenAccessDownloadTask`
  /// / `OverdriveDownloadTask`) are recreated on every audiobook open, so if each
  /// created its own `URLSession` with the (now-stable, F1) identifier, a reopen
  /// spawned a SECOND live background session sharing the identifier — undefined
  /// behavior, whose delegate callbacks stop firing, so the reopened player's
  /// progress bar looks frozen while the original session keeps downloading.
  /// Owning the session here (GET-OR-CREATE in `session(forIdentifier:...)`) makes
  /// it survive player close and be reused on reopen instead of duplicated.
  private var ownedSessions: [String: URLSession] = [:]

  /// Durable router delegates for the coordinator-owned sessions, retained
  /// alongside their session (a `URLSession` retains its delegate, but we keep an
  /// explicit reference so the type is available for observer re-registration).
  private var ownedSessionDelegates: [String: DurableSessionRouterDelegate] = [:]

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
    ATLog(.debug, "AudiobookDownloadCoordinator: Initialized")
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
      ATLog(.debug, "AudiobookDownloadCoordinator: Registered completion handler for session: \(identifier)")
    }
  }
  
  /// Calls and removes the completion handler for a background session.
  /// This must be called on the main thread as required by iOS.
  ///
  /// - Parameter identifier: The background session identifier
  public func callCompletionHandler(forSessionIdentifier identifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let handler = self?.backgroundCompletionHandlers.removeValue(forKey: identifier) else {
        ATLog(.warn, "AudiobookDownloadCoordinator: No completion handler found for session: \(identifier)")
        return
      }
      
      DispatchQueue.main.async {
        ATLog(.info, "AudiobookDownloadCoordinator: Calling completion handler for session: \(identifier)")
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
      ATLog(.debug, "AudiobookDownloadCoordinator: Stored reconnected session: \(identifier)")
    }
    
    downloadStatePublisher.send(.sessionReconnected(sessionIdentifier: identifier))
  }

  // MARK: - Coordinator-Owned Session Registry (F2)

  /// Returns the coordinator-owned background `URLSession` for `identifier`,
  /// creating it (via `configure`) on first use and REUSING the live one on
  /// every subsequent call. This guarantees exactly one live background session
  /// per identifier across audiobook close/reopen: the per-track download task
  /// that outlives player close keeps its session here, and the freshly-created
  /// task on reopen reuses it (re-registering itself as the current observer)
  /// instead of spawning a duplicate that iOS would treat as undefined behavior.
  ///
  /// The router delegate that owns the session forwards its callbacks to a
  /// swappable current observer; `registerObserver(_:forIdentifier:)` swaps it.
  ///
  /// - Parameters:
  ///   - identifier: The background-session identifier (stable per book+track).
  ///   - configure: Builds the `URLSession` on first use for this identifier.
  ///     Called with the durable router delegate that MUST be set as the
  ///     session's delegate. Only invoked on a cache miss.
  /// - Returns: The live coordinator-owned session for `identifier`.
  func session(
    forIdentifier identifier: String,
    configure: (DurableSessionRouterDelegate) -> URLSession
  ) -> URLSession {
    queue.sync(flags: .barrier) {
      if let existing = ownedSessions[identifier] {
        ATLog(.debug, "AudiobookDownloadCoordinator: Reusing owned session: \(identifier)")
        return existing
      }
      let router = DurableSessionRouterDelegate(sessionIdentifier: identifier)
      let session = configure(router)
      ownedSessions[identifier] = session
      ownedSessionDelegates[identifier] = router
      ATLog(.debug, "AudiobookDownloadCoordinator: Created owned session: \(identifier)")
      return session
    }
  }

  /// Swaps the current observer the durable router for `identifier` forwards to.
  /// Called by each download task in `downloadAsset` so the CURRENT player's
  /// task receives progress/completion, even after a previous task (from a prior
  /// open) was released. The router holds the observer weakly and guards the
  /// swap with its own lock, so a released observer simply stops receiving
  /// callbacks. Safe to call before or after `session(forIdentifier:...)`.
  func registerObserver(_ observer: DownloadTaskObserver, forIdentifier identifier: String) {
    let router: DurableSessionRouterDelegate? = queue.sync {
      ownedSessionDelegates[identifier]
    }
    router?.setCurrentObserver(observer)
  }

  /// Invalidates and forgets the coordinator-owned session for `identifier`,
  /// cancelling any in-flight task. Call ONLY from explicit-cancel or the
  /// retry/token-refresh paths that deliberately tear the session down before
  /// re-fetching — NOT on player close (F2 keeps the session alive there). The
  /// next `session(forIdentifier:)` for this identifier then creates a fresh
  /// session, so a stale invalidated session is never reused.
  func discardOwnedSession(forIdentifier identifier: String) {
    queue.sync(flags: .barrier) {
      if let session = ownedSessions.removeValue(forKey: identifier) {
        session.invalidateAndCancel()
        ATLog(.debug, "AudiobookDownloadCoordinator: Discarded owned session: \(identifier)")
      }
      ownedSessionDelegates.removeValue(forKey: identifier)
    }
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

          // The download is finalized on disk, so the map should no longer
          // retain it. Leaving a `.completed` entry accretes forever (both F1
          // reviewers flagged this): it reloads every launch and never gets a
          // production `removeActiveDownload` caller. Remove it here so the
          // persisted state is bounded to genuinely in-flight downloads.
          self.activeDownloads.removeValue(forKey: sessionIdentifier)

          ATLog(.info, "AudiobookDownloadCoordinator: Download completed and moved to: \(destinationURL.path)")

          DispatchQueue.main.async {
            self.downloadStatePublisher.send(.downloadCompleted(sessionIdentifier: sessionIdentifier, fileURL: destinationURL))
          }

          // Persist the updated (pruned) state
          self.persistState()

        } catch {
          ATLog(.error, "AudiobookDownloadCoordinator: Failed to move downloaded file: \(error.localizedDescription)")
          downloadInfo.state = .failed
          self.activeDownloads[sessionIdentifier] = downloadInfo
          
          DispatchQueue.main.async {
            self.downloadStatePublisher.send(.downloadFailed(sessionIdentifier: sessionIdentifier, error: error))
          }
        }
      } else {
        ATLog(.warn, "AudiobookDownloadCoordinator: No download info found for session: \(sessionIdentifier)")
        
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
      
      ATLog(.error, "AudiobookDownloadCoordinator: Download failed for session \(sessionIdentifier): \(error.localizedDescription)")
      
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
      
      ATLog(.debug, "AudiobookDownloadCoordinator: Registered active download for session: \(sessionIdentifier)")
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
      ATLog(.debug, "AudiobookDownloadCoordinator: Removed active download for session: \(sessionIdentifier)")
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
      ATLog(.error, "AudiobookDownloadCoordinator: Cannot get persistence URL")
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
      
      ATLog(.debug, "AudiobookDownloadCoordinator: Persisted \(activeDownloads.count) downloads to disk")
    } catch {
      ATLog(.error, "AudiobookDownloadCoordinator: Failed to persist state: \(error.localizedDescription)")
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
      
      // Convert back to DownloadInfo, pruning terminal entries so the map
      // stays bounded across launches. An entry is dropped if it is already
      // `.completed`/`.failed`, or if its destination file already exists on
      // disk (the download finished out-of-band — e.g. the in-process success
      // path moved the file without touching the coordinator). Only genuinely
      // in-flight downloads survive the reload.
      activeDownloads = persistedDownloads.compactMapValues { persisted in
        guard let originalURL = URL(string: persisted.originalURL),
              let localDestination = URL(string: persisted.localDestination),
              let state = DownloadInfo.DownloadState(rawValue: persisted.state) else {
          return nil
        }

        if state == .completed || state == .failed {
          return nil
        }
        if FileManager.default.fileExists(atPath: localDestination.path) {
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

      ATLog(.info, "AudiobookDownloadCoordinator: Loaded \(activeDownloads.count) persisted downloads")
    } catch {
      ATLog(.debug, "AudiobookDownloadCoordinator: No persisted state found or failed to load: \(error.localizedDescription)")
    }
  }
  
  /// Clears all persisted state (for testing or reset).
  public func clearAllState() {
    queue.async(flags: .barrier) { [weak self] in
      self?.activeDownloads.removeAll()
      self?.reconnectedSessions.removeAll()
      self?.backgroundCompletionHandlers.removeAll()

      // Let owned sessions drain any in-flight tasks rather than cancelling
      // them (a hard `invalidateAndCancel` would kill a live download — the
      // exact thing F2 must not do). `finishTasksAndInvalidate` completes
      // outstanding tasks, then invalidates. We drop our references so the
      // registry is empty for a fresh start / test isolation.
      self?.ownedSessions.values.forEach { $0.finishTasksAndInvalidate() }
      self?.ownedSessions.removeAll()
      self?.ownedSessionDelegates.removeAll()
      
      if let url = self?.persistenceURL {
        try? FileManager.default.removeItem(at: url)
      }
      
      ATLog(.info, "AudiobookDownloadCoordinator: Cleared all state")
    }
  }
  
  /// Migrates all audiobook downloads from Caches to Application Support.
  /// This prevents iOS from purging downloaded audiobook files.
  /// Call this once during app startup.
  public static func migrateDownloadsFromCaches() {
    OpenAccessDownloadTask.migrateFromCachesIfNeeded()
    OverdriveDownloadTask.migrateFromCachesIfNeeded()
    ATLog(.info, "AudiobookDownloadCoordinator: Completed download migration check")
  }
}

// MARK: - DownloadTaskObserver (F2)

/// The three `URLSessionDownloadDelegate` callbacks the durable router forwards
/// to the CURRENT download task. `DownloadTaskURLSessionDelegate` (which holds
/// all the completion/error/retry/token-refresh/resume-data logic) conforms to
/// this; the router calls through without duplicating any of that logic.
///
/// `AnyObject` so the router can hold the current observer WEAKLY — a task from
/// a prior audiobook open must be free to deallocate, at which point it simply
/// stops receiving callbacks (and `didFinishDownloadingTo` falls back to the
/// coordinator's durable finalization — see the router).
protocol DownloadTaskObserver: AnyObject {
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL)
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  )
}

// MARK: - DurableSessionRouterDelegate (F2)

/// The delegate of a coordinator-owned background `URLSession`. It is created
/// once per identifier and lives for the app's lifetime, forwarding session
/// callbacks to whichever download task is CURRENTLY observing (the one the
/// live player just created). Because a `URLSession`'s delegate is fixed at
/// creation, this indirection is what lets a reopened player receive live
/// progress on a session that a prior task created.
///
/// Thread-safety: `currentObserver` is read on the session's background
/// delegate queue and written from `downloadAsset`; both go through `lock`.
/// The observer is held weakly so a released prior task deallocates cleanly.
final class DurableSessionRouterDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {
  private let sessionIdentifier: String
  private let lock = NSLock()
  private weak var currentObserver: DownloadTaskObserver?

  init(sessionIdentifier: String) {
    self.sessionIdentifier = sessionIdentifier
    super.init()
  }

  /// Swaps the observer the router forwards to. Guarded by `lock`.
  func setCurrentObserver(_ observer: DownloadTaskObserver) {
    lock.lock()
    currentObserver = observer
    lock.unlock()
  }

  private func snapshotObserver() -> DownloadTaskObserver? {
    lock.lock()
    defer { lock.unlock() }
    return currentObserver
  }

  // MARK: URLSessionDownloadDelegate

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    if let observer = snapshotObserver() {
      observer.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
      return
    }

    // REFINEMENT 1: no live observer (the download completed between player
    // close and reopen). Dropping here would LOSE the finished file — worse
    // than a frozen bar. Finalize durably via the F1 path, which uses the
    // `registerActiveDownload` mapping (`downloadAsset` records it) to move the
    // temp file to its destination. Round-2's load-prune later reaps the entry.
    guard let originalURL = downloadTask.originalRequest?.url else {
      ATLog(.error, "DurableSessionRouterDelegate: completed with no observer AND no original URL: \(sessionIdentifier)")
      return
    }
    ATLog(.info, "DurableSessionRouterDelegate: no observer — finalizing via coordinator F1 path: \(sessionIdentifier)")
    AudiobookDownloadCoordinator.shared.handleBackgroundDownloadCompletion(
      sessionIdentifier: sessionIdentifier,
      downloadedFileURL: location,
      originalURL: originalURL
    )
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // No live observer → safe to drop: there is no player to surface the error
    // to, and no file to finalize (a nil-error completion is handled by
    // `didFinishDownloadingTo` above; a non-nil error has nothing to move).
    snapshotObserver()?.urlSession(session, task: task, didCompleteWithError: error)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    // No live observer → safe to drop: progress with no player to show it is
    // meaningless, and the reopened player re-derives progress from file state.
    snapshotObserver()?.urlSession(
      session,
      downloadTask: downloadTask,
      didWriteData: bytesWritten,
      totalBytesWritten: totalBytesWritten,
      totalBytesExpectedToWrite: totalBytesExpectedToWrite
    )
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
