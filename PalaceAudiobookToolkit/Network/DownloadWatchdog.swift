//
//  DownloadWatchdog.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

/// Monitors audiobook downloads and detects/recovers from stalled downloads.
/// A download is considered "stalled" if it makes no progress for a configurable period.
///
/// ## Synchronization
///
/// This class deliberately keeps **two** synchronization domains. They are
/// disjoint, and each one guards state the other cannot reach safely:
///
/// - **`queue` (concurrent + barrier) guards the download bookkeeping** —
///   `monitoredDownloads`, `retryTasks` and `cancellables`. Every mutation runs
///   inside `queue.async(flags: .barrier)` or `queue.sync(flags: .barrier)`;
///   every read runs inside a barrier block or a plain `queue.sync`. That is
///   the classic reader/writer pattern: concurrent readers, exclusive writers.
///   A `.concurrent` queue only serializes writes when the write carries
///   `.barrier`, so the invariant is specifically *barrier on every write*, not
///   merely *on the queue*.
/// - **`lifecycle` (lock) guards the run flag and the monitoring task handle.**
///
/// The lifecycle state is not folded into `queue` because it must be readable
/// from inside the monitoring `Task` and the retry `Task` on every tick. Doing
/// that through `queue.sync` would block a cooperative thread behind whatever
/// barrier is currently in flight — and one of those barriers calls
/// `downloadTask.fetch()`. A short uncontended lock has no such coupling.
/// Conversely the bookkeeping is not folded into the lock, because that would
/// mean holding a lock across `fetch()`.
///
/// Neither domain's lock is ever held across an acquisition of the other, so
/// the two cannot deadlock against each other.
///
/// `@unchecked Sendable` is sound by construction: the class has five stored
/// properties and none of them is unguarded mutable state.
/// - `configuration` — `let`, and `Configuration` is `Sendable`.
/// - `eventPublisher` — `let`. The reference cannot be reseated, and every
///   `send` this class performs is funnelled through `DispatchQueue.main.async`,
///   so the watchdog never publishes concurrently with itself. What a
///   subscriber does on receipt remains the subscriber's concern.
/// - `queue`, `lifecycle` — `let`, and both types are `Sendable`.
/// - `monitoredDownloads`, `retryTasks`, `cancellables` — mutable, but reachable
///   only under the barrier discipline described above.
///
/// Do not add a stored property that is neither `let` nor covered by one of the
/// two domains; that would invalidate this conformance.
public final class DownloadWatchdog: @unchecked Sendable {
  
  // MARK: - Configuration
  
  public struct Configuration: Sendable {
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
  
  /// State of a monitored download.
  ///
  /// Not `Sendable`, and cannot become so while `downloadTask` is an
  /// `any DownloadTask`: the protocol is `AnyObject` without a `Sendable`
  /// refinement, so the existential carries an unsynchronized reference. Every
  /// other stored property is a `Sendable` value type, so the day
  /// `DownloadTask` refines `Sendable` this struct conforms for free.
  ///
  /// Until then the rule is: a `MonitoredDownload` never leaves the barrier
  /// queue. Where a value from one is needed elsewhere (a main-queue event
  /// notification), copy out the scalar fields instead of capturing the struct.
  private struct MonitoredDownload {
    let trackKey: String
    let downloadTask: DownloadTask
    var lastProgress: Float
    var lastProgressTime: Date
    var retryCount: Int
    var isStalled: Bool
  }

  /// A `Sendable` reduction of `DownloadTaskState`.
  ///
  /// `DownloadTaskState.error` carries `any Error`, which is not `Sendable`, so
  /// the state itself must not be handed to the barrier queue. Everything the
  /// watchdog actually needs from it — the progress value, and the error's
  /// description for the log line — is extracted on the thread that delivered
  /// the state, and only those `Sendable` values cross.
  private enum StateSummary: Sendable {
    case progress(Float)
    case completed
    case failed(description: String)
    case deleted

    init(_ state: DownloadTaskState) {
      switch state {
      case .progress(let progress):
        self = .progress(progress)
      case .completed:
        self = .completed
      case .error(let error):
        self = .failed(description: error?.localizedDescription ?? "unknown")
      case .deleted:
        self = .deleted
      }
    }
  }

  /// Events published by the watchdog
  public enum WatchdogEvent: Sendable {
    case downloadStalled(trackKey: String, retryCount: Int)
    case downloadRetrying(trackKey: String, attempt: Int, maxAttempts: Int)
    case downloadRecovered(trackKey: String)
    case downloadFailed(trackKey: String, reason: String)
  }
  
  // MARK: - Properties
  
  public let configuration: Configuration
  public let eventPublisher = PassthroughSubject<WatchdogEvent, Never>()
  
  // Download bookkeeping — guarded by `queue`; barrier on every write.
  private var monitoredDownloads: [String: MonitoredDownload] = [:]
  private var retryTasks: [String: Task<Void, Never>] = [:]
  private var cancellables = Set<AnyCancellable>()
  private let queue = DispatchQueue(label: "com.palace.downloadWatchdog", attributes: .concurrent)

  /// Run flag and monitoring-task handle, held together so that starting and
  /// stopping is a single atomic step.
  ///
  /// They were previously separate: the flag sat behind an `NSLock` while the
  /// task handle was a bare `var` guarded by nothing at all. That split made
  /// two races possible, both of which end with a timer nobody can cancel:
  /// `stop()` could nil out a handle that a concurrent `start()` was about to
  /// overwrite, and two `start()` calls could each install one.
  private struct Lifecycle: Sendable {
    var isRunning = false
    var monitoringTask: Task<Void, Never>?
  }

  private let lifecycle = LockIsolated(Lifecycle())

  /// Read-only view of the run flag, for the periodic tick and the retry task.
  /// Mutation goes through `lifecycle.withValue` so that test-and-set is atomic —
  /// a separate `get` then `set` is not.
  private var isRunning: Bool { lifecycle.value.isRunning }

  // MARK: - Initialization
  
  public init(configuration: Configuration = .default) {
    self.configuration = configuration
  }
  
  deinit {
    stop()
  }
  
  // MARK: - Public API
  
  /// Starts monitoring downloads using AsyncStream for periodic checks.
  ///
  /// - Returns: `true` if this call transitioned the watchdog from stopped to
  ///   running, `false` if it was already running. Exactly one of any number of
  ///   concurrent calls can return `true`; that is the invariant which keeps a
  ///   second monitoring task from being installed and orphaned. Marked
  ///   `@discardableResult` so existing callers are unaffected.
  @discardableResult
  public func start() -> Bool {
    // Atomic test-and-set. `guard !isRunning` followed by `isRunning = true` is
    // two separate lock acquisitions, so two concurrent `start()` calls could
    // both observe `false` and both proceed. Each would then install a
    // monitoring Task, and the second assignment would drop the first Task's
    // handle on the floor — leaving a timer running that `stop()` has no
    // handle to cancel, firing stall checks (and therefore retries) for the
    // rest of the process's life.
    let didStart = lifecycle.withValue { state -> Bool in
      guard !state.isRunning else { return false }
      state.isRunning = true
      return true
    }
    guard didStart else { return false }

    ATLog(.info, "DownloadWatchdog: Starting with stallTimeout=\(configuration.stallTimeout)s, maxRetries=\(configuration.maxRetries)")

    // Capture the interval out-of-line so the Task body does not need `self`
    // for stream setup. The body intentionally does not strong-rebind `self`
    // at the top — holding a strong reference across the full for-await
    // would pin the instance's lifetime to the Task, so the instance could
    // never deinit while the stream was still emitting. With per-iteration
    // weak-unwrap we release `self` between ticks; when `stop()` cancels the
    // Task, the stream exits on the next iteration and the Task returns
    // without ever having held `self` strongly.
    let interval = configuration.checkInterval
    let task = Task { [weak self] in
      for await _ in Self.timerStream(interval: interval) {
        guard let self = self, self.isRunning else { break }
        self.checkForStalledDownloads()
      }
    }

    // Publish the handle under the same lock. A `stop()` that landed between
    // the test-and-set above and here has already cleared the flag and found
    // no handle to cancel, so storing one now would hand `stop()`'s successor
    // a task it never started. Cancel it here instead. The loop would also
    // have exited on its own at the next tick (it re-reads `isRunning`); this
    // just makes the teardown immediate and the handle bookkeeping honest.
    let installed = lifecycle.withValue { state -> Bool in
      guard state.isRunning else { return false }
      state.monitoringTask = task
      return true
    }
    if !installed {
      task.cancel()
    }
    return true
  }

  /// Creates an AsyncStream that emits at regular intervals.
  private static func timerStream(interval: TimeInterval) -> AsyncStream<Date> {
    AsyncStream { continuation in
      let task = Task {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
          guard !Task.isCancelled else { break }
          continuation.yield(Date())
        }
        continuation.finish()
      }
      
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
  
  /// Stops monitoring downloads. Synchronous and idempotent — safe to call
  /// from `deinit`, from `stop()` itself (it guards via `isRunning`), or
  /// repeatedly from any thread. After this returns, no watchdog-owned
  /// state remains on the internal barrier queue.
  public func stop() {
    // Clear the flag and take ownership of the handle in one atomic step, so
    // that two concurrent `stop()` calls (an explicit stop racing `deinit`)
    // cannot both come away holding the same task, and so that a `start()`
    // interleaving between a read and a nil-out cannot have its freshly
    // installed handle discarded.
    let monitoringTask = lifecycle.withValue { state -> Task<Void, Never>? in
      state.isRunning = false
      let task = state.monitoringTask
      state.monitoringTask = nil
      return task
    }

    // Cancelled outside the lock: cancellation runs any registered handlers
    // synchronously on the calling thread, and none of that should execute
    // with the lifecycle lock held.
    monitoringTask?.cancel()

    // Cancel pending retry tasks and clear all state in a single synchronous
    // barrier. The previous implementation issued `queue.sync { ... }` for
    // cancellation and then fire-and-forgot `queue.async(flags: .barrier)`
    // for clear-out, which meant stop() returned before state was actually
    // cleared. If the caller was `deinit`, the instance would finish
    // deallocating while that async barrier was still in flight, racing
    // the still-terminating monitoring Task.
    queue.sync(flags: .barrier) {
      for (_, task) in retryTasks {
        task.cancel()
      }
      retryTasks.removeAll()
      monitoredDownloads.removeAll()
      cancellables.removeAll()
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

      // Copy out the one scalar the notification needs. Reading it through
      // `monitored` inside the closure would capture the whole
      // non-`Sendable` struct, and capture it *by reference* — `monitored` is
      // a `var`, so the closure would read whatever it holds whenever the main
      // queue gets around to running, not the value at the point of send.
      let attempt = monitored.retryCount

      // Re-fetch the download
      monitored.downloadTask.fetch()

      DispatchQueue.main.async {
        self.eventPublisher.send(.downloadRetrying(
          trackKey: trackKey,
          attempt: attempt,
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
    // Reduce to `Sendable` values on the delivering thread (this is called from
    // the main queue, via the subscription's `receive(on:)`). `DownloadTaskState`
    // itself must not cross onto the barrier queue: its `.error` case carries an
    // `any Error`, whose thread-safety is unknown to us — `localizedDescription`
    // on a bridged NSError can lazily populate internal storage, so evaluating it
    // on whichever thread happens to service the barrier is exactly the race we
    // are removing. The rendered log text is identical.
    let summary = StateSummary(state)

    queue.async(flags: .barrier) { [weak self] in
      guard let self = self,
            var monitored = self.monitoredDownloads[trackKey] else {
        return
      }

      switch summary {
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
        
      case .failed(let description):
        ATLog(.warn, "DownloadWatchdog: Download error for track \(trackKey): \(description)")
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

          // Copied out for the same reason as in `retryDownload`: the closure
          // must not capture the non-`Sendable` `monitored`, and must not read
          // a mutable `var` by reference from another queue.
          let retryCount = monitored.retryCount

          DispatchQueue.main.async {
            self.eventPublisher.send(.downloadStalled(trackKey: trackKey, retryCount: retryCount))
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
    // Cancel any existing retry task for this track
    queue.async(flags: .barrier) { [weak self] in
      self?.retryTasks[trackKey]?.cancel()
    }
    
    let task = Task { [weak self] in
      guard let self = self else { return }
      
      do {
        try await Task.sleep(nanoseconds: UInt64(self.configuration.retryDelay * 1_000_000_000))
      } catch {
        // Task was cancelled
        return
      }
      
      guard self.isRunning, !Task.isCancelled else { return }
      
      // Clean up the tracked task
      self.queue.async(flags: .barrier) {
        self.retryTasks.removeValue(forKey: trackKey)
      }
      
      self.retryDownload(trackKey: trackKey)
    }
    
    // Track the task so it can be cancelled
    queue.async(flags: .barrier) { [weak self] in
      self?.retryTasks[trackKey] = task
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
