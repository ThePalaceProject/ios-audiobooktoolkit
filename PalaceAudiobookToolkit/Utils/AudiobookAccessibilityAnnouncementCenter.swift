//
//  AudiobookAccessibilityAnnouncementCenter.swift
//  PalaceAudiobookToolkit
//
//  Created by The Palace Project on 2/6/26.
//

import UIKit

public final class AudiobookAccessibilityAnnouncementCenter {
  public typealias PostHandler = (UIAccessibility.Notification, String) -> Void
  public typealias VoiceOverRunningProvider = () -> Bool

  private let postHandler: PostHandler
  private let isVoiceOverRunning: VoiceOverRunningProvider
  private let progressStep: Int
  private var lastProgressBucketByKey: [String: Int] = [:]

  public init(
    postHandler: @escaping PostHandler = { UIAccessibility.post(notification: $0, argument: $1) },
    isVoiceOverRunning: @escaping VoiceOverRunningProvider = { UIAccessibility.isVoiceOverRunning },
    progressStep: Int = 20
  ) {
    self.postHandler = postHandler
    self.isVoiceOverRunning = isVoiceOverRunning
    self.progressStep = max(5, progressStep)
  }

  public func announceDownloadStarted(title: String) {
    announce(Strings.DownloadAnnouncements.downloadStarted(title))
  }

  public func announceDownloadCompleted(title: String) {
    announce(Strings.DownloadAnnouncements.downloadCompleted(title))
  }

  public func announceDownloadFailed(title: String) {
    announce(Strings.DownloadAnnouncements.downloadFailed(title))
  }

  public func announceDownloadProgress(title: String, identifier: String, progress: Double) {
    let percent = progressPercent(progress)
    guard percent < 100 else { return }
    let bucket = progressBucket(for: percent)
    guard shouldAnnounceProgress(identifier: identifier, bucket: bucket) else { return }
    announce(Strings.DownloadAnnouncements.downloadProgress(title, percent))
  }

  public func resetProgress(identifier: String) {
    lastProgressBucketByKey.removeValue(forKey: identifier)
  }

  // MARK: - Private

  private func announce(_ message: String) {
    guard isVoiceOverRunning() else { return }
    DispatchQueue.main.async { [postHandler] in
      postHandler(.announcement, message)
    }
  }

  private func progressPercent(_ progress: Double) -> Int {
    let clamped = max(0.0, min(1.0, progress))
    return Int((clamped * 100.0).rounded(.down))
  }

  private func progressBucket(for percent: Int) -> Int {
    guard percent > 0 else { return 0 }
    return (percent / progressStep) * progressStep
  }

  private func shouldAnnounceProgress(identifier: String, bucket: Int) -> Bool {
    guard bucket > 0 else { return false }
    let lastBucket = lastProgressBucketByKey[identifier] ?? -progressStep
    guard bucket > lastBucket else { return false }
    lastProgressBucketByKey[identifier] = bucket
    return true
  }
}
