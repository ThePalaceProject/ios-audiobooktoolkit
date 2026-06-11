//
//  FindawayDownloadEngineGate.swift
//  PalaceAudiobookToolkit
//
//  Serializes all access to the shared Findaway download engine.
//

import Foundation

/// Serializes **all** access to the shared, non-thread-safe Findaway
/// `FAEDownloadEngine` (`FAEAudioEngine.shared().downloadEngine`).
///
/// Findaway's `FAEChapterStatus` SQLite cache guards itself with an internal
/// `dispatch_semaphore`. That semaphore is not safe for concurrent use: calling
/// `status(forAudiobookID:…)` / `startDownload` / `delete` from more than one
/// thread at a time traps in `_dispatch_semaphore_dispose.cold.1`
/// ("semaphore object deallocated while in use").
///
/// Each `FindawayDownloadTask` runs on its **own** per-chapter serial queue, and
/// `DefaultAudiobookNetworkService` fans out up to `maxConcurrentTrackDownloads`
/// downloads plus per-second poll loops. Opening a multi-chapter audiobook
/// therefore drives concurrent `status(forAudiobookID:)` calls into the one
/// shared engine, which crashed on device (audiobookID 32884, "Dune").
///
/// Routing every download-engine call through this single serial queue removes
/// the data race while preserving each call's synchronous return value and
/// ordering. Calls are short (an in-memory/SQLite lookup), so serializing them
/// is cheap relative to the network downloads they coordinate.
///
/// - Important: Never call `perform` from the gate's own queue; the SDK calls
///   routed through it do not re-enter the gate, so this cannot happen in
///   normal use.
final class FindawayDownloadEngineGate {
  static let shared = FindawayDownloadEngineGate()

  private let queue = DispatchQueue(
    label: "org.nypl.labs.PalaceAudiobookToolkit.FindawayDownloadEngineGate"
  )

  init() {}

  /// Runs `work` on the gate's serial queue and returns its result. Safe to
  /// call from any thread other than the gate's own queue.
  @discardableResult
  func perform<T>(_ work: () -> T) -> T {
    queue.sync(execute: work)
  }
}
