//
//  DownloadWatchdog.swift
//  PalaceAudiobookToolkit
//
//  Created for Audiobook Reliability Fix
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Monitors audiobook downloads and detects/recovers from stalled downloads.
/// A download is considered "stalled" if it makes no progress for a configurable period.
public final class DownloadWatchdog {
  
  // MARK: - Configuration
  
  public struct Configuration {
    /// Time without progress before a download is considered stalled
    public let stallTimeout: TimeInterval
    
    /// Maximum number of automatic retry attempts
    public let maxRetries: Int
    
    /// Delay between retry attempts
    public let retryDelay: TimeInterval
    
    /// How often to check for stalled downloads
    public let checkInterval: TimeInterval
    
    public static let `default` = Configuration(
      stallTimeout: 45.0,
      maxRetries: 3,
      retryDelay: 5.0,
      checkInterval: 10.0
    )
    
    public init(
      stallTimeout: TimeInterval = 45.0,
      maxRetries: Int = 3,
      retryDelay: TimeInterval = 5.0,
      checkInterval: TimeInterval = 10.0
    ) {
      self.stallTimeout = stallTimeout
      self.maxRetries = maxRetries
      self.retryDelay = retryDelay
      self.checkInterval = checkInterval
    }
  }
  
  // MARK: - Types
  
  /// State of a monitored download
  private struct MonitoredDownload {
    let trackKey: String
    let downloadTask: DownloadTask
    var lastProgress: Float
    var lastProgressTime: Date
    var retryCount: Int
    var isStalled: Bool
  }
  
  /// Events published by the watchdog
  public enum WatchdogEvent {
    case downloadStalled(trackKey: String, retryCount: Int)
    case downloadRetrying(trackKey: String, attempt: Int, maxAttempts: Int)
    case downloadRecovered(trackKey: String)
    case downloadFailed(trackKey: String, reason: String)
  }
  
  // MARK: - Properties
  
  public let configuration: Configuration
  public let eventPublisher = PassthroughSubject<WatchdogEvent, Never>()
  
  private var monitoredDownloads: [String: MonitoredDownload] = [:]
  private var checkTimer: Timer?
  private var cancellables = Set<AnyCancellable>()
  private let queue = DispatchQueue(label: "com.palace.downloadWatchdog", attributes: .concurrent)
  private var isRunning = false
  
  // MARK: - Initialization
  
  public init(configuration: Configuration = .default) {
    self.configuration = configuration
  }
  
  deinit {
    stop()
  }
  
  // MARK: - Public API
  
  /// Starts monitoring downloads.
  public func start() {
    guard !isRunning else { return }
    isRunning = true
    
    ATLog(.info, "DownloadWatchdog: Starting with stallTimeout=\(configuration.stallTimeout)s, maxRetries=\(configuration.maxRetries)")
    
    // Start periodic check timer
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.checkTimer?.invalidate()
      self.checkTimer = Timer.scheduledTimer(
        withTimeInterval: self.configuration.checkInterval,
        repeats: true
      ) { [weak self] _ in
        self?.checkForStalledDownloads()
      }
    }
  }
  
  /// Stops monitoring downloads.
  public func stop() {
    isRunning = false
    
    DispatchQueue.main.async { [weak self] in
      self?.checkTimer?.invalidate()
      self?.checkTimer = nil
    }
    
    queue.async(flags: .barrier) { [weak self] in
      self?.monitoredDownloads.removeAll()
      self?.cancellables.removeAll()
    }
    
    ATLog(.info, "DownloadWatchdog: Stopped")
  }
  
  /// Registers a download task for monitoring.
  ///
  /// - Parameters:
  ///   - trackKey: The unique key for the track
  ///   - downloadTask: The download task to monitor
  public func monitor(trackKey: String, downloadTask: DownloadTask) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      let monitored = MonitoredDownload(
        trackKey: trackKey,
        downloadTask: downloadTask,
        lastProgress: downloadTask.downloadProgress,
        lastProgressTime: Date(),
        retryCount: 0,
        isStalled: false
      )
      
      self.monitoredDownloads[trackKey] = monitored
      
      // Subscribe to progress updates
      downloadTask.statePublisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state in
          self?.handleDownloadState(state, forTrackKey: trackKey)
        }
        .store(in: &self.cancellables)
      
      ATLog(.debug, "DownloadWatchdog: Now monitoring track: \(trackKey)")
    }
  }
  
  /// Stops monitoring a specific download.
  ///
  /// - Parameter trackKey: The track key to stop monitoring
  public func stopMonitoring(trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      self?.monitoredDownloads.removeValue(forKey: trackKey)
      ATLog(.debug, "DownloadWatchdog: Stopped monitoring track: \(trackKey)")
    }
  }
  
  /// Manually triggers a retry for a stalled download.
  ///
  /// - Parameter trackKey: The track key to retry
  public func retryDownload(trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var monitored = self.monitoredDownloads[trackKey] else {
        return
      }
      
      ATLog(.info, "DownloadWatchdog: Manual retry requested for track: \(trackKey)")
      
      monitored.retryCount += 1
      monitored.isStalled = false
      monitored.lastProgressTime = Date()
      self.monitoredDownloads[trackKey] = monitored
      
      // Re-fetch the download
      monitored.downloadTask.fetch()
      
      DispatchQueue.main.async {
        self.eventPublisher.send(.downloadRetrying(
          trackKey: trackKey,
          attempt: monitored.retryCount,
          maxAttempts: self.configuration.maxRetries
        ))
      }
    }
  }
  
  /// Returns current status of all monitored downloads.
  public var status: [String: (progress: Float, isStalled: Bool, retryCount: Int)] {
    queue.sync {
      return monitoredDownloads.mapValues { ($0.lastProgress, $0.isStalled, $0.retryCount) }
    }
  }
  
  // MARK: - Private Methods
  
  private func handleDownloadState(_ state: DownloadTaskState, forTrackKey trackKey: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var monitored = self.monitoredDownloads[trackKey] else {
        return
      }
      
      switch state {
      case .progress(let progress):
        // Update progress tracking
        if progress > monitored.lastProgress {
          monitored.lastProgress = progress
          monitored.lastProgressTime = Date()
          monitored.isStalled = false
          self.monitoredDownloads[trackKey] = monitored
          
          // If download was previously stalled and is now making progress, notify recovery
          if monitored.retryCount > 0 {
            DispatchQueue.main.async {
              self.eventPublisher.send(.downloadRecovered(trackKey: trackKey))
            }
          }
        }
        
      case .completed:
        ATLog(.debug, "DownloadWatchdog: Download completed for track: \(trackKey)")
        self.monitoredDownloads.removeValue(forKey: trackKey)
        
      case .error(let error):
        ATLog(.warn, "DownloadWatchdog: Download error for track \(trackKey): \(error?.localizedDescription ?? "unknown")")
        // Don't remove - let the periodic check handle retry
        monitored.isStalled = true
        self.monitoredDownloads[trackKey] = monitored
        
      case .deleted:
        ATLog(.debug, "DownloadWatchdog: Download deleted for track: \(trackKey)")
        self.monitoredDownloads.removeValue(forKey: trackKey)
      }
    }
  }
  
  private func checkForStalledDownloads() {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      let now = Date()
      
      for (trackKey, var monitored) in self.monitoredDownloads {
        // Skip completed downloads
        if monitored.lastProgress >= 1.0 {
          continue
        }
        
        let timeSinceProgress = now.timeIntervalSince(monitored.lastProgressTime)
        
        if timeSinceProgress >= self.configuration.stallTimeout && !monitored.isStalled {
          // Download is stalled
          monitored.isStalled = true
          self.monitoredDownloads[trackKey] = monitored
          
          ATLog(.warn, "DownloadWatchdog: Download stalled for track: \(trackKey) (no progress for \(Int(timeSinceProgress))s)")
          
          DispatchQueue.main.async {
            self.eventPublisher.send(.downloadStalled(trackKey: trackKey, retryCount: monitored.retryCount))
          }
          
          // Attempt automatic retry if within limits
          if monitored.retryCount < self.configuration.maxRetries {
            self.scheduleRetry(forTrackKey: trackKey)
          } else {
            ATLog(.error, "DownloadWatchdog: Max retries exceeded for track: \(trackKey)")
            DispatchQueue.main.async {
              self.eventPublisher.send(.downloadFailed(
                trackKey: trackKey,
                reason: "Download stalled after \(self.configuration.maxRetries) retry attempts"
              ))
            }
          }
        }
      }
    }
  }
  
  private func scheduleRetry(forTrackKey trackKey: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + configuration.retryDelay) { [weak self] in
      self?.retryDownload(trackKey: trackKey)
    }
  }
}

// MARK: - Convenience Extension for AudiobookNetworkService

extension DefaultAudiobookNetworkService {
  
  /// Creates and starts a watchdog for all tracks in this service.
  ///
  /// - Parameter configuration: Optional custom configuration
  /// - Returns: The created watchdog
  public func createWatchdog(configuration: DownloadWatchdog.Configuration = .default) -> DownloadWatchdog {
    let watchdog = DownloadWatchdog(configuration: configuration)
    
    for track in tracks {
      if let downloadTask = track.downloadTask {
        watchdog.monitor(trackKey: track.key, downloadTask: downloadTask)
      }
    }
    
    watchdog.start()
    return watchdog
  }
}
