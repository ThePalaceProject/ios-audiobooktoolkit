//
//  FindawayPlaybackNotificationHandler.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/5/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import AudioEngine
import PalaceAudiobookToolkit

protocol FindawayPlaybackNotificationHandlerDelegate: class {
    func audioEnginePlaybackStarted(_ notificationHandler: FindawayPlaybackNotificationHandler, for chapter: FAEChapterDescription)
    func audioEnginePlaybackPaused(_ notificationHandler: FindawayPlaybackNotificationHandler, for chapter: FAEChapterDescription)
    func audioEnginePlaybackFinished(_ notificationHandler: FindawayPlaybackNotificationHandler, for chapter: FAEChapterDescription)
    func audioEnginePlaybackFailed(_ notificationHandler: FindawayPlaybackNotificationHandler, withError error: NSError?, for chapter: FAEChapterDescription)
    func audioEngineAudiobookCompleted(_ notificationHandler: FindawayPlaybackNotificationHandler, for audiobookID: String)
}

protocol FindawayPlaybackNotificationHandler {
    var delegate: FindawayPlaybackNotificationHandlerDelegate? { get set }
}

/// This class wraps notifications from AudioEngine and notifies its delegate. It has no behavior on its own and should only be used to get updates on playback/streaming status from AudioEngine.
class DefaultFindawayPlaybackNotificationHandler: NSObject, FindawayPlaybackNotificationHandler {
    weak var delegate: FindawayPlaybackNotificationHandlerDelegate?
    public override init() {
        super.init()
        
        // Chapter Playback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(DefaultFindawayPlaybackNotificationHandler.audioEngineChapterPlaybackStarted(_:)),
            name: NSNotification.Name.FAEPlaybackChapterStarted,
            object: nil
        )
        // It has been observed that this notification does not come
        // right away when the chapter completes, sometimes it takes
        // multiple seconds to arrive.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(DefaultFindawayPlaybackNotificationHandler.audioEngineChapterDidComplete(_:)),
            name: NSNotification.Name.FAEPlaybackChapterComplete,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(DefaultFindawayPlaybackNotificationHandler.audioEngineChapterPlaybackPaused(_:)),
            name: NSNotification.Name.FAEPlaybackChapterPaused,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(DefaultFindawayPlaybackNotificationHandler.audioEngineChapterPlaybackFailed(_:)),
            name: NSNotification.Name.FAEPlaybackChapterFailed,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(DefaultFindawayPlaybackNotificationHandler.audioEngineAudiobookCompleted(_:)),
            name: NSNotification.Name.FAEPlaybackAudiobookComplete,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func audioEngineChapterDidComplete(_ notification: NSNotification) {
        if let chapter = notification.userInfo?[FAEChapterDescriptionUserInfoKey] as? FAEChapterDescription {
            self.delegate?.audioEnginePlaybackFinished(self, for: chapter)
        }
    }

    @objc func audioEngineChapterPlaybackStarted(_ notification: NSNotification) {
        if let chapter = notification.userInfo?[FAEChapterDescriptionUserInfoKey] as? FAEChapterDescription {
            self.delegate?.audioEnginePlaybackStarted(self, for: chapter)
        }
    }
    
    @objc func audioEngineChapterPlaybackPaused(_ notification: NSNotification) {
        if let chapter = notification.userInfo?[FAEChapterDescriptionUserInfoKey] as? FAEChapterDescription {
            self.delegate?.audioEnginePlaybackPaused(self, for: chapter)
        }
    }

    @objc func audioEngineChapterPlaybackFailed(_ notification: NSNotification) {
        guard let chapter = notification.userInfo?[FAEChapterDescriptionUserInfoKey] as? FAEChapterDescription else { return }
        let error = notification.userInfo?[FAEAudioEngineErrorUserInfoKey] as? NSError
        self.delegate?.audioEnginePlaybackFailed(self, withError: error, for: chapter)
    }
    
    @objc func audioEngineAudiobookCompleted(_ notification: NSNotification) {
        if let audiobookID = notification.userInfo?[FAEAudiobookIDUserInfoKey] as? String {
            self.delegate?.audioEngineAudiobookCompleted(self, for: audiobookID)
        }
    }
}
