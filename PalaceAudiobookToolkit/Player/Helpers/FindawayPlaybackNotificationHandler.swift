//
//  FindawayPlaybackNotificationHandler.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/5/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AudioEngine
import PalaceAudiobookToolkit
import UIKit

// MARK: - FindawayPlaybackNotificationHandlerDelegate

/// Main-actor isolated: every implementation drives playback state, and the
/// handler now guarantees delivery on the main queue.
@MainActor
protocol FindawayPlaybackNotificationHandlerDelegate: class {
  func audioEnginePlaybackStarted(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for chapter: FAEChapterDescription
  )
  func audioEnginePlaybackPaused(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for chapter: FAEChapterDescription
  )
  func audioEnginePlaybackFinished(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for chapter: FAEChapterDescription
  )
  func audioEnginePlaybackFailed(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    withError error: NSError?,
    for chapter: FAEChapterDescription
  )
  func audioEngineAudiobookCompleted(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for audiobookID: String
  )
}

// MARK: - FindawayPlaybackNotificationHandler

protocol FindawayPlaybackNotificationHandler {
  var delegate: FindawayPlaybackNotificationHandlerDelegate? { get set }
}

// MARK: - DefaultFindawayPlaybackNotificationHandler

/// This class wraps notifications from AudioEngine and notifies its delegate. It has no behavior on its own and should only be used to get updates on playback/streaming status from AudioEngine.
/// Removes its notification tokens when it deallocates.
///
/// Block-based observers are NOT removed automatically the way
/// selector-based ones have been since iOS 9, so something must own them.
/// Giving them their own box means the handler needs no `deinit` — reaching
/// for stored properties from a nonisolated `deinit` is an error in the Swift 6
/// language mode.
private final class NotificationTokenBox {
  var tokens: [NSObjectProtocol] = []
  deinit {
    tokens.forEach { NotificationCenter.default.removeObserver($0) }
  }
}

/// This class wraps notifications from AudioEngine and notifies its delegate. It has no behavior on its own and should only be used to get updates on playback/streaming status from AudioEngine.
///
/// Observers are registered with `queue: .main`, so AudioEngine's notifications
/// — which arrive on the SDK's own threads — are delivered on the main queue.
/// That is what makes the delegate safe to isolate: previously each conformer
/// hopped by hand with `DispatchQueue.main.async`, or forgot to.
@MainActor
class DefaultFindawayPlaybackNotificationHandler: NSObject, FindawayPlaybackNotificationHandler {
  weak var delegate: FindawayPlaybackNotificationHandlerDelegate?
  private let tokenBox = NotificationTokenBox()

  override public init() {
    super.init()

    // Chapter Playback
    observe(.FAEPlaybackChapterStarted) { [weak self] chapter, _ in
      guard let self else { return }
      self.delegate?.audioEnginePlaybackStarted(self, for: chapter)
    }
    // It has been observed that this notification does not come
    // right away when the chapter completes, sometimes it takes
    // multiple seconds to arrive.
    observe(.FAEPlaybackChapterComplete) { [weak self] chapter, _ in
      guard let self else { return }
      self.delegate?.audioEnginePlaybackFinished(self, for: chapter)
    }
    observe(.FAEPlaybackChapterPaused) { [weak self] chapter, _ in
      guard let self else { return }
      self.delegate?.audioEnginePlaybackPaused(self, for: chapter)
    }
    observe(.FAEPlaybackChapterFailed) { [weak self] chapter, notification in
      guard let self else { return }
      let error = notification.userInfo?[FAEAudioEngineErrorUserInfoKey] as? NSError
      self.delegate?.audioEnginePlaybackFailed(self, withError: error, for: chapter)
    }

    let audiobookToken = NotificationCenter.default.addObserver(
      forName: .FAEPlaybackAudiobookComplete, object: nil, queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self,
              let audiobookID = notification.userInfo?[FAEAudiobookIDUserInfoKey] as? String
        else { return }
        self.delegate?.audioEngineAudiobookCompleted(self, for: audiobookID)
      }
    }
    tokenBox.tokens.append(audiobookToken)
  }

  /// Observe a chapter notification on the main queue and hand the decoded
  /// `FAEChapterDescription` to `body`. `assumeIsolated` is sound here because
  /// `queue: .main` guarantees the block runs on the main thread.
  private func observe(
    _ name: Notification.Name,
    _ body: @escaping @MainActor (FAEChapterDescription, Notification) -> Void
  ) {
    let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
      MainActor.assumeIsolated {
        guard let chapter = notification.userInfo?[FAEChapterDescriptionUserInfoKey] as? FAEChapterDescription
        else { return }
        body(chapter, notification)
      }
    }
    tokenBox.tokens.append(token)
  }
}
