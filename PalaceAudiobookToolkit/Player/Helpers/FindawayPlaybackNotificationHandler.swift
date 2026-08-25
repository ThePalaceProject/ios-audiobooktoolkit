//
//  FindawayPlaybackNotificationHandler.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/5/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AudioEngine
import UIKit

// MARK: - FindawayChapterRef

/// The part of an AudioEngine chapter notification we actually use.
///
/// `FAEChapterDescription` is an SDK type with no Sendable guarantee, and it
/// arrives on AudioEngine's own thread while every consumer is main-actor. It
/// therefore cannot cross the isolation boundary — "sending 'chapter' risks
/// causing data races", an error in the Swift 6 language mode. Rewriting the
/// hop does not help; the object itself is what cannot travel.
///
/// Every consumer only ever reads these two numbers (a track lookup and one log
/// line), so the notification is decoded on the SDK's thread and this crosses
/// instead.
///
/// This type must stay UNISOLATED, and that is the whole point of it: it is
/// built on AudioEngine's thread, which is the one place a main-actor
/// initialiser cannot be called. A doc comment once separated the delegate
/// protocol's `@MainActor` from the protocol, so the attribute landed here and
/// silently made the value object main-actor — "call to main actor-isolated
/// initializer 'init(partNumber:chapterNumber:)' in a synchronous nonisolated
/// context". A warning today; in the Swift 6 language mode it is the error that
/// stops the decode from compiling at all.
public struct FindawayChapterRef: Sendable, Equatable {
  public let partNumber: Int
  public let chapterNumber: Int

  public init(partNumber: Int, chapterNumber: Int) {
    self.partNumber = partNumber
    self.chapterNumber = chapterNumber
  }
}

// MARK: - FindawayPlaybackNotificationHandlerDelegate

/// Main-actor isolated: every implementation drives playback state, and the
/// handler now guarantees delivery on the main queue.
@MainActor
protocol FindawayPlaybackNotificationHandlerDelegate: AnyObject {
  func audioEnginePlaybackStarted(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for chapter: FindawayChapterRef
  )
  func audioEnginePlaybackPaused(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for chapter: FindawayChapterRef
  )
  func audioEnginePlaybackFinished(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for chapter: FindawayChapterRef
  )
  func audioEnginePlaybackFailed(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    withError error: NSError?,
    for chapter: FindawayChapterRef
  )
  func audioEngineAudiobookCompleted(
    _ notificationHandler: FindawayPlaybackNotificationHandler,
    for audiobookID: String
  )
}

// MARK: - FindawayPlaybackNotificationHandler

/// Isolated with its delegate and its only conformer: the handler holds a
/// `@MainActor` delegate and delivers on the main queue, so the property
/// requirement is main-actor too.
@MainActor
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
    observe(.FAEPlaybackChapterFailed) { [weak self] chapter, error in
      guard let self else { return }
      self.delegate?.audioEnginePlaybackFailed(self, withError: error, for: chapter)
    }

    let audiobookToken = NotificationCenter.default.addObserver(
      forName: .FAEPlaybackAudiobookComplete, object: nil, queue: .main
    ) { [weak self] notification in
      // `String` is Sendable; `Notification` is not. Decode before the hop.
      let audiobookID = notification.userInfo?[FAEAudiobookIDUserInfoKey] as? String
      MainActor.assumeIsolated {
        guard let self, let audiobookID else { return }
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
    _ body: @escaping @MainActor @Sendable (FindawayChapterRef, NSError?) -> Void
  ) {
    let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
      // Decode OUTSIDE the isolated closure. `Notification` is not Sendable, so
      // capturing it into `assumeIsolated` is "sending 'notification' risks
      // causing data races" — an error in the Swift 6 language mode. Only the
      // decoded values cross.
      let sdkChapter = notification.userInfo?[FAEChapterDescriptionUserInfoKey] as? FAEChapterDescription
      let chapter = sdkChapter.map {
        FindawayChapterRef(partNumber: Int($0.partNumber), chapterNumber: Int($0.chapterNumber))
      }
      let error = notification.userInfo?[FAEAudioEngineErrorUserInfoKey] as? NSError
      MainActor.assumeIsolated {
        guard let chapter else { return }
        body(chapter, error)
      }
    }
    tokenBox.tokens.append(token)
  }
}
