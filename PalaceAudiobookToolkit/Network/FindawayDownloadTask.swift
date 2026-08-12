//
//  FindawayLibrarian.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/22/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AudioEngine
import Combine
import UIKit

// MARK: - FindawayDownloadTask

/// - Note: `@unchecked Sendable` is justified by construction rather than by
///   assertion. Every stored property is one of:
///   * a `let`: `statePublisher`, `key`, `audiobookID`, `partNumber`,
///     `chapterNumber`, `pollRate`, `queue`, `notificationHandler`;
///   * lock-guarded: `_downloadProgress`, `_readyToDownload`,
///     `_retryAfterVerification`, `_pollAgainForPercentageAt`,
///     `_notifiedDownloadProgress`;
///   * confined to the private serial `queue`: `downloadRequest`. That is the
///     one property that cannot move into a `LockIsolated`, because
///     `FAEDownloadRequest` is not `Sendable`. Every access to it outside
///     `init` happens inside a `queue.async(flags: .barrier)` block, and the
///     chapter identity that off-queue callers need is held separately as the
///     three `let`s below — which is what makes that confinement true rather
///     than aspirational.
///   Adding a plain `var` stored property here invalidates this reasoning.
final class FindawayDownloadTask: DownloadTask, @unchecked Sendable {
  let statePublisher = PassthroughSubject<DownloadTaskState, Never>()
  let key: String
  var needsRetry: Bool {
    switch downloadStatus {
    case .notDownloaded:
      true
    default:
      false
    }
  }

  /// The Findaway request this task drives.
  ///
  /// Confined to `queue`: assigned in `init`, replaced only from
  /// `findawayDownloadNotificationHandler(_:didDeleteAudiobookFor:)`, and read
  /// only from blocks already running on `queue`.
  private var downloadRequest: FAEDownloadRequest

  /// The chapter this task downloads.
  ///
  /// `downloadRequest` is swapped for a fresh object after a delete, but the
  /// replacement copies these three fields verbatim (see
  /// `didDeleteAudiobookFor:`) and `FAEDownloadRequest` declares all of its
  /// properties `readonly`, so they are constant for the task's lifetime.
  /// Holding them separately is what lets off-queue callers — `needsRetry`,
  /// the main-thread progress hop, and `isTaskFor` on the notification thread
  /// — identify the chapter without reading the queue-confined
  /// `downloadRequest`.
  private let audiobookID: String
  private let partNumber: UInt
  private let chapterNumber: UInt

  /// Lock-guarded: written from the Findaway engine's progress callbacks and
  /// read by the UI for the progress bar, so plain stored access was a data
  /// race. Publishing still happens on main and still re-reads the current
  /// value there, preserving the previous `didSet` semantics (every set
  /// publishes, even when the value is unchanged).
  private let _downloadProgress = LockIsolated<Float>(0)
  var downloadProgress: Float {
    get { _downloadProgress.value }
    set {
      _downloadProgress.value = newValue
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          return
        }
        statePublisher.send(.progress(downloadProgress))
        notifiedDownloadProgress = downloadProgress
      }
    }
  }

  private let pollRate: TimeInterval = 1.0

  /// Poll bookkeeping. Every read and write already runs on the serial
  /// `queue`, which is also what keeps the read-modify-write in
  /// `didStartDownloadFor:` ("if no poll is scheduled, schedule one") atomic —
  /// the lock only guarantees each individual access. The box is here so that
  /// no member of this type is left unguarded, which is what the
  /// `@unchecked Sendable` note above depends on.
  private let _pollAgainForPercentageAt = LockIsolated<Date?>(nil)
  private var pollAgainForPercentageAt: Date? {
    get { _pollAgainForPercentageAt.value }
    set { _pollAgainForPercentageAt.value = newValue }
  }

  /// Written by `attemptFetch()` and read by the `readyToDownload` setter,
  /// both on `queue`; boxed for the same reason as the poll date above.
  private let _retryAfterVerification = LockIsolated(false)
  private var retryAfterVerification: Bool {
    get { _retryAfterVerification.value }
    set { _retryAfterVerification.value = newValue }
  }

  /// Lock-guarded: written from `queue` (`delete()`, the delete notification,
  /// database verification) but read from the main thread by
  /// `updateDownloadProgress()` and from any thread at all via `needsRetry`,
  /// so plain stored access was a data race.
  ///
  /// The setter reproduces, by hand, the `didSet` this property used to carry:
  /// a property observer does not run for a box's storage, so moving the
  /// storage would otherwise have dropped the `attemptFetch()` trigger
  /// silently. The reproduction is deliberately literal — it still fires on
  /// *every* set (including one that does not change the value), still
  /// re-reads the stored value after the write rather than trusting
  /// `newValue`, and still runs after the store, so `attemptFetch()` observes
  /// the new value. `init` assigns `_readyToDownload` directly, which
  /// preserves the other half of the old semantics: a `didSet` does not fire
  /// for the initializer's assignment.
  private let _readyToDownload: LockIsolated<Bool>
  private var readyToDownload: Bool {
    get { _readyToDownload.value }
    set {
      _readyToDownload.value = newValue
      guard readyToDownload else {
        return
      }
      guard retryAfterVerification else {
        return
      }
      attemptFetch()
    }
  }

  private var downloadStatus: FAEDownloadStatus {
    var status = FAEDownloadStatus.notDownloaded
    guard readyToDownload else {
      return status
    }

    let statusFromFindaway = FindawayDownloadEngineGate.shared.perform {
      FAEAudioEngine.shared()?.downloadEngine?.status(
        forAudiobookID: audiobookID,
        partNumber: partNumber,
        chapterNumber: chapterNumber
      )
    }
    if let storedStatus = statusFromFindaway {
      status = storedStatus
    }
    return status
  }

  private var downloadEngineIsFree: Bool {
    guard readyToDownload else {
      return false
    }

    return FindawayDownloadEngineGate.shared.perform {
      FAEAudioEngine.shared()?.downloadEngine?.currentDownloadRequests().isEmpty ?? false
    }
  }

  private let queue: DispatchQueue

  /// Written on the main thread from the `downloadProgress` publish hop below.
  /// Nothing reads it today — it is the record of the last value actually
  /// published — but it is storage all the same, so it is guarded rather than
  /// left to invalidate the `Sendable` reasoning above.
  private let _notifiedDownloadProgress = LockIsolated<Float>(.nan)
  private var notifiedDownloadProgress: Float {
    get { _notifiedDownloadProgress.value }
    set { _notifiedDownloadProgress.value = newValue }
  }

  private let notificationHandler: FindawayDownloadNotificationHandler
  public init(
    databaseVerification: FindawayDatabaseVerification,
    findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler,
    downloadRequest: FAEDownloadRequest,
    key: String
  ) {
    self.downloadRequest = downloadRequest
    audiobookID = downloadRequest.audiobookID
    partNumber = downloadRequest.partNumber
    chapterNumber = downloadRequest.chapterNumber
    notificationHandler = findawayDownloadNotificationHandler
    // Assign the box, not the computed property: the stored property's `didSet`
    // did not run for this assignment, and a computed setter would have.
    _readyToDownload = LockIsolated(databaseVerification.verified)
    queue = DispatchQueue(label: "org.nypl.labs.PalaceAudiobookToolkit.FindawayDownloadTask/\(key)")
    self.key = key
    notificationHandler.delegate = self
    if !readyToDownload {
      databaseVerification.registerDelegate(self)
    }
  }

  convenience init(
    audiobookID: String,
    chapterNumber: UInt,
    partNumber: UInt,
    sessionKey: String,
    licenseID: String
  ) {
    var request: FAEDownloadRequest! = FindawayDownloadEngineGate.shared.perform {
      FAEAudioEngine.shared()?.downloadEngine?.currentDownloadRequests()
        .first(where: { existingRequest -> Bool in
          return existingRequest.audiobookID == audiobookID
            && existingRequest.chapterNumber == chapterNumber
            && existingRequest.partNumber == partNumber
        })
    }

    if request == nil {
      request = FAEDownloadRequest(
        audiobookID: audiobookID,
        partNumber: partNumber,
        chapterNumber: chapterNumber,
        downloadType: .singleChapter,
        sessionKey: sessionKey,
        licenseID: licenseID,
        restrictToWiFi: false
      )
    }
    self.init(
      databaseVerification: FindawayDatabaseVerification.shared,
      findawayDownloadNotificationHandler: DefaultFindawayDownloadNotificationHandler(),
      downloadRequest: request,
      key: "FAE.audioEngine/\(request.audiobookID)/\(request.partNumber)/\(request.chapterNumber)"
    )
  }

  public func fetch() {
    queue.async(flags: .barrier) {
      self.attemptFetch()
    }
  }

  private func attemptFetch() {
    guard readyToDownload else {
      retryAfterVerification = true
      return
    }

    let status = downloadStatus
    if status == .notDownloaded {
      FindawayDownloadEngineGate.shared.perform {
        FAEAudioEngine.shared()?.downloadEngine?.startDownload(with: downloadRequest)
      }
      retryAfterVerification = false
      pollAgainForPercentageAt = Date().addingTimeInterval(pollRate) // Ensure polling starts
      pollForDownloadPercentage()
    } else if status == .downloaded {
      downloadProgress = 1.0
      statePublisher.send(.completed)
    }
  }

  func nextScheduledPoll() -> DispatchTime {
    DispatchTime.now() + pollRate
  }

  func pollForDownloadPercentage() {
    queue.asyncAfter(deadline: nextScheduledPoll()) {
      if self.downloadStatus == .downloading {
        self.updateDownloadProgress()
        self.pollAgainForPercentageAt = Date().addingTimeInterval(self.pollRate)
        self.pollForDownloadPercentage()
      } else if self.downloadStatus == .downloaded {
        self.downloadProgress = 1.0
        self.statePublisher.send(.completed)
        self.pollAgainForPercentageAt = nil
      } else {
        self.pollAgainForPercentageAt = nil
      }
    }
  }

  private func updateDownloadProgress() {
    DispatchQueue.main.async { [weak self] in
      guard let self, readyToDownload else {
        self?.downloadProgress = 0
        return
      }

      // Reads the immutable chapter identity rather than `downloadRequest`:
      // this block runs on the main thread, and `downloadRequest` is confined
      // to `queue`.
      let progress = findawayProgressToNYPLToolkit(
        FindawayDownloadEngineGate.shared.perform {
          FAEAudioEngine.shared()?.downloadEngine?.percentage(
            forAudiobookID: self.audiobookID,
            partNumber: self.partNumber,
            chapterNumber: self.chapterNumber
          )
        }
      )

      if progress == 1.0 {
        downloadProgress = 1.0
        statePublisher.send(.completed)
      } else {
        downloadProgress = progress
      }
    }
  }

  public func delete() {
    queue.async(flags: .barrier) {
      FindawayDownloadEngineGate.shared.perform {
        FAEAudioEngine.shared()?.downloadEngine?.delete(
          forAudiobookID: self.audiobookID,
          partNumber: self.partNumber,
          chapterNumber: self.chapterNumber
        )
      }
      self.readyToDownload = false
    }
  }

  func assetFileStatus() -> AssetResult {
    .unknown
  }
}

// MARK: FindawayDownloadNotificationHandlerDelegate

extension FindawayDownloadTask: FindawayDownloadNotificationHandlerDelegate {
  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didPauseDownloadFor chapterDescription: FAEChapterDescription
  ) {
    // The `isTaskFor` check moves ahead of the hop rather than into it.
    // It reads only immutable `let`s, so its result does not depend on when it
    // runs, and it has no side effects — but keeping it here means the
    // notification's `FAEChapterDescription`, whose properties are `readwrite`
    // and therefore genuinely unsafe to share, stays on the thread that
    // delivered it instead of being sent to `queue`. Same shape in the three
    // handlers below.
    guard isTaskFor(chapterDescription) else {
      return
    }
    queue.async(flags: .barrier) {
      self.pollAgainForPercentageAt = nil
    }
  }

  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didSucceedDownloadFor chapterDescription: FAEChapterDescription
  ) {
    guard isTaskFor(chapterDescription) else {
      return
    }
    queue.async(flags: .barrier) {
      self.pollAgainForPercentageAt = nil
      self.downloadProgress = 1.0
      self.statePublisher.send(.completed)
    }
  }

  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didStartDownloadFor chapterDescription: FAEChapterDescription
  ) {
    guard isTaskFor(chapterDescription) else {
      return
    }
    queue.async(flags: .barrier) {
      guard self.pollAgainForPercentageAt == nil else {
        return
      }
      self.pollAgainForPercentageAt = Date().addingTimeInterval(self.pollRate)
      self.pollForDownloadPercentage()
    }
  }

  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didReceive error: NSError,
    for downloadRequestID: String
  ) {
    queue.async(flags: .barrier) {
      if self.downloadRequest.requestIdentifier == downloadRequestID {
        self.pollAgainForPercentageAt = nil
        self.statePublisher.send(.error(error))
      }
    }
  }

  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didDeleteAudiobookFor chapterDescription: FAEChapterDescription
  ) {
    guard isTaskFor(chapterDescription) else {
      return
    }
    queue.async(flags: .barrier) {
      self.statePublisher.send(.deleted)
      // The three identity fields come from the `let`s rather than from the
      // outgoing request. That is the same value either way — it is why the
      // `let`s are valid — but taking them from here makes the invariant the
      // rest of the type relies on structural instead of incidental.
      self.downloadRequest = FAEDownloadRequest(
        audiobookID: self.audiobookID,
        partNumber: self.partNumber,
        chapterNumber: self.chapterNumber,
        downloadType: self.downloadRequest.downloadType,
        sessionKey: self.downloadRequest.sessionKey,
        licenseID: self.downloadRequest.licenseID,
        restrictToWiFi: self.downloadRequest.restrictToWiFi
      )
      self.readyToDownload = true
    }
  }

  func isTaskFor(_ chapter: FAEChapterDescription) -> Bool {
    audiobookID == chapter.audiobookID &&
      chapterNumber == chapter.chapterNumber &&
      partNumber == chapter.partNumber
  }
}

// MARK: FindawayDatabaseVerificationDelegate

extension FindawayDownloadTask: FindawayDatabaseVerificationDelegate {
  func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification) {
    // Read `verified` here rather than inside the hop, so the verification
    // object — an unsynchronized `NSObject` — is not sent to `queue`. The flag
    // is only ever written once, `false` -> `true`
    // (`FindawayAudiobookLifecycleListener`), and this callback is delivered
    // from that write's `didSet`, so the value read here is the value the
    // block would have read.
    let verified = findawayDatabaseVerification.verified
    queue.async(flags: .barrier) {
      self.readyToDownload = verified
    }
  }
}

private func findawayProgressToNYPLToolkit(_ progress: Float?) -> Float {
  var toolkitProgress: Float = 0
  if let progress = progress {
    toolkitProgress = progress / 100
  }
  return toolkitProgress
}
