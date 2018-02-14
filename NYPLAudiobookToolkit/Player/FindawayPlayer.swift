//
//  FindawayPlayer.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/31/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import AudioEngine

class FindawayPlayer: NSObject, Player {
    private var currentChapterLocation: ChapterLocation {
        let findaway = self.currentFindawayChapter
        let duration = self.currentBookIsPlaying ? TimeInterval(self.currentDuration) : (self.spineElement.duration ?? 0)
        return ChapterLocation(
            number: findaway?.chapterNumber ?? self.spineElement.chapterNumber,
            part: findaway?.partNumber ?? self.spineElement.partNumber,
            duration: duration,
            offset: TimeInterval(self.currentOffset)
        )
    }
    weak var delegate: PlayerDelegate?
    private var resumePlaybackDescription: ChapterLocation?
    // Only queue the last issued command if they are issued before Findaway has been verified
    private var queuedLocation: ChapterLocation?
    private var readyForPlayback = false {
        didSet {
            if let location = self.queuedLocation {
                self.playAtLocation(location)
                self.queuedLocation = nil
            }
        }
    }

    private var sessionKey: String {
        return self.spineElement.sessionKey
    }

    private var licenseID: String {
        return self.spineElement.licenseID
    }

    private var audiobookID: String {
        return self.spineElement.audiobookID
    }

    /// If no book is loaded, AudioEngine returns 0, so this is consistent with their behavior
    private var currentOffset: UInt {
        return FAEAudioEngine.shared()?.playbackEngine?.currentOffset ?? 0
    }

    /// If no book is loaded, AudioEngine returns 0, so this is consistent with their behavior
    private var currentDuration: UInt {
        return FAEAudioEngine.shared()?.playbackEngine?.currentDuration ?? 0
    }

    var currentBookIsPlaying: Bool {
        return self.isPlaying && self.bookIsLoaded
    }

    private var currentFindawayChapter: FAEChapterDescription? {
        var chapter: FAEChapterDescription? = nil
        if self.isPlaying {
            // If there is no book playing the SDK will still return a loaded chapter, this chapter will have a blank audiobook ID and must not be used. Will cause undefined behavior.
            chapter = FAEAudioEngine.shared()?.playbackEngine?.currentLoadedChapter()
        }
        return chapter
    }

    var isPlaying: Bool {
        return FAEAudioEngine.shared()?.playbackEngine?.playerStatus == FAEPlayerStatus.playing
    }

    private var bookIsLoaded: Bool {
        guard let loadedAudiobookID = self.currentFindawayChapter?.audiobookID else { return false }
        return loadedAudiobookID == self.audiobookID
    }

    private let spineElement: FindawaySpineElement
    private var eventHandler: FindawayPlaybackNotificationHandler
    public init(spineElement: FindawaySpineElement, eventHandler: FindawayPlaybackNotificationHandler) {
        self.eventHandler = eventHandler
        self.spineElement = spineElement
        super.init()
        self.eventHandler.delegate = self
    }
    
    convenience init(spineElement: FindawaySpineElement) {
        self.init(spineElement: spineElement, eventHandler: DefaultFindawayPlaybackNotificationHandler())
    }

    func skipForward() {
        let someTimeFromNow = self.currentOffset + 15
        let offsetDescription = self.currentChapterLocation.chapterWith(TimeInterval(someTimeFromNow))
        self.jumpToChapter(offsetDescription)
    }

    func skipBack() {
        let someTimeAgo = Int(self.currentOffset) - 15
        let timeToGoBackTo = UInt(max(0, someTimeAgo))
        let offsetDescription = self.currentChapterLocation.chapterWith(TimeInterval(timeToGoBackTo))
        self.jumpToChapter(offsetDescription)
    }

    func play() {
        if let resumeCommand = self.resumePlaybackDescription {
            self.jumpToChapter(resumeCommand)
        } else {
            self.jumpToChapter(
                self.currentChapterLocation.chapterWith(0)
            )
        }
    }

    
    func pause() {
        if let chapter = self.currentFindawayChapter {
            self.resumePlaybackDescription = ChapterLocation(
                number: chapter.chapterNumber,
                part: chapter.partNumber,
                duration: TimeInterval(self.currentDuration),
                offset: TimeInterval(self.currentOffset)
            )
        }
        FAEAudioEngine.shared()?.playbackEngine?.pause()
    }
    
    func jumpToChapter(_ chapter: ChapterLocation) {
        guard !self.readyForPlayback else {
            self.queuedLocation = chapter
            return
        }

        if self.currentBookIsPlaying {
            if self.chapterIsCurrentlyPlaying(chapter) {
                FAEAudioEngine.shared()?.playbackEngine?.currentOffset = UInt(chapter.offset)
                self.delegate?.player(self, didBeginPlaybackOf: chapter)
            } else {
                self.playAtLocation(chapter)
            }
        } else if self.isResumeDescription(chapter) {
            FAEAudioEngine.shared()?.playbackEngine?.resume()
        } else {
            self.playAtLocation(chapter)
        }
    }
    
    func playAtLocation(_ chapter: ChapterLocation) {
        FAEAudioEngine.shared()?.playbackEngine?.play(
            forAudiobookID: self.audiobookID,
            partNumber: chapter.part,
            chapterNumber: chapter.number,
            offset: UInt(chapter.offset),
            sessionKey: self.sessionKey,
            licenseID: self.licenseID
        )
    }
    
    func chapterIsCurrentlyPlaying(_ chapter: ChapterLocation) -> Bool {
        guard let findawayChapter = self.currentFindawayChapter else { return false }
        return findawayChapter.partNumber == chapter.part &&
            findawayChapter.chapterNumber == chapter.number
    }

    func isResumeDescription(_ chapter: ChapterLocation) -> Bool {
        guard let resumeDescription = self.resumePlaybackDescription else {
            return false
        }
        return resumeDescription === chapter
    }
}

extension FindawayPlayer: AudiobookLifecycleManagerDelegate {
    func audiobookLifecycleManagerDidUpdate(_ audiobookLifecycleManager: AudiobookLifeCycleManager) {
        self.readyForPlayback = audiobookLifecycleManager.audioEngineDatabaseHasBeenVerified
    }
    
    // TODO: Update this to pass the chapter that the error happened to instead of audiobook id
    func audiobookLifecycleManager(_ audiobookLifecycleManager: AudiobookLifeCycleManager, didRecieve error: AudiobookError) {
    }
}

extension FindawayPlayer: FindawayPlaybackNotificationHandlerDelegate {
    func audioEngineChapterPlaybackStarted(_ notificationHandler: FindawayPlaybackNotificationHandler) {
        if let chapter = self.currentFindawayChapter {
            let chapterLocation = ChapterLocation(
                number: chapter.chapterNumber,
                part: chapter.partNumber,
                duration: TimeInterval(self.currentDuration),
                offset: TimeInterval(self.currentOffset)
            )
            self.delegate?.player(self, didBeginPlaybackOf: chapterLocation)
        }
    }
    
    func audioEngineChapterPlaybackPaused(_ notificationHandler: FindawayPlaybackNotificationHandler) {
        if let chapter = self.currentFindawayChapter {
            let chapterLocation = ChapterLocation(
                number: chapter.chapterNumber,
                part: chapter.partNumber,
                duration: TimeInterval(self.currentDuration),
                offset: TimeInterval(self.currentOffset)
            )
            self.delegate?.player(self, didStopPlaybackOf: chapterLocation)
        }
    }
}
