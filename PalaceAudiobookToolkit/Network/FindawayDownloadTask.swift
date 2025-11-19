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

final class FindawayDownloadTask: DownloadTask {
  var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
  var key: String
  var needsRetry: Bool {
    switch downloadStatus {
    case .notDownloaded:
      true
    default:
      false
    }
  }

  private var downloadRequest: FAEDownloadRequest
  private var session: URLSession?
  private var downloadTask: DownloadTask?

  var downloadProgress: Float = 0 {
    didSet {
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
  private var pollAgainForPercentageAt: Date?
  private var retryAfterVerification = false
  private var readyToDownload: Bool {
    didSet {
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

    let statusFromFindaway = FAEAudioEngine.shared()?.downloadEngine?.status(
      forAudiobookID: downloadRequest.audiobookID,
      partNumber: downloadRequest.partNumber,
      chapterNumber: downloadRequest.chapterNumber
    )
    if let storedStatus = statusFromFindaway {
      status = storedStatus
    }
    return status
  }

  private var downloadEngineIsFree: Bool {
    guard readyToDownload else {
      return false
    }

    return FAEAudioEngine.shared()?.downloadEngine?.currentDownloadRequests().isEmpty ?? false
  }

  private let queue: DispatchQueue
  private var notifiedDownloadProgress: Float = .nan
  private let notificationHandler: FindawayDownloadNotificationHandler
  public init(
    databaseVerification: FindawayDatabaseVerification,
    findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler,
    downloadRequest: FAEDownloadRequest,
    key: String
  ) {
    self.downloadRequest = downloadRequest
    notificationHandler = findawayDownloadNotificationHandler
    readyToDownload = databaseVerification.verified
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
    var request: FAEDownloadRequest! = FAEAudioEngine.shared()?.downloadEngine?.currentDownloadRequests()
      .first(where: { existingRequest -> Bool in
        return existingRequest.audiobookID == audiobookID
          && existingRequest.chapterNumber == chapterNumber
          && existingRequest.partNumber == partNumber
      })

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
      FAEAudioEngine.shared()?.downloadEngine?.startDownload(with: downloadRequest)
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

      let progress = findawayProgressToNYPLToolkit(
        FAEAudioEngine.shared()?.downloadEngine?.percentage(
          forAudiobookID: downloadRequest.audiobookID,
          partNumber: downloadRequest.partNumber,
          chapterNumber: downloadRequest.chapterNumber
        )
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
      FAEAudioEngine.shared()?.downloadEngine?.delete(
        forAudiobookID: self.downloadRequest.audiobookID,
        partNumber: self.downloadRequest.partNumber,
        chapterNumber: self.downloadRequest.chapterNumber
      )
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
    queue.async(flags: .barrier) {
      guard self.isTaskFor(chapterDescription) else {
        return
      }
      self.pollAgainForPercentageAt = nil
    }
  }

  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didSucceedDownloadFor chapterDescription: FAEChapterDescription
  ) {
    queue.async(flags: .barrier) {
      guard self.isTaskFor(chapterDescription) else {
        return
      }
      self.pollAgainForPercentageAt = nil
      self.downloadProgress = 1.0
      self.statePublisher.send(.completed)
    }
  }

  func findawayDownloadNotificationHandler(
    _: FindawayDownloadNotificationHandler,
    didStartDownloadFor chapterDescription: FAEChapterDescription
  ) {
    queue.async(flags: .barrier) {
      guard self.isTaskFor(chapterDescription) else {
        return
      }
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
    queue.async(flags: .barrier) {
      if self.isTaskFor(chapterDescription) {
        self.statePublisher.send(.deleted)
        self.downloadRequest = FAEDownloadRequest(
          audiobookID: self.downloadRequest.audiobookID,
          partNumber: self.downloadRequest.partNumber,
          chapterNumber: self.downloadRequest.chapterNumber,
          downloadType: self.downloadRequest.downloadType,
          sessionKey: self.downloadRequest.sessionKey,
          licenseID: self.downloadRequest.licenseID,
          restrictToWiFi: self.downloadRequest.restrictToWiFi
        )
        self.readyToDownload = true
      }
    }
  }

  func isTaskFor(_ chapter: FAEChapterDescription) -> Bool {
    downloadRequest.audiobookID == chapter.audiobookID &&
      downloadRequest.chapterNumber == chapter.chapterNumber &&
      downloadRequest.partNumber == chapter.partNumber
  }
}

// MARK: FindawayDatabaseVerificationDelegate

extension FindawayDownloadTask: FindawayDatabaseVerificationDelegate {
  func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification) {
    queue.async(flags: .barrier) {
      self.readyToDownload = findawayDatabaseVerification.verified
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
