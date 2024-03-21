//
//  AudiobookManager.swift
//  NYPLAudibookKit
//
//  Created by Dean Silfen on 1/12/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import MediaPlayer
import AVFoundation

/// If the AudiobookManager runs into an error that may
/// be resolved by fetching a new audiobook manifest from
/// the server, it will request the parent disposes
/// of itself and instantiate a new manager with a new
/// manifest
@objc public protocol RefreshDelegate {

    /**
     Will be called when the manager determines it has reached an error
     that should be resolved by refreshing the AudiobookManager
     */
    func audiobookManagerDidRequestRefresh()
}

@objc public protocol AudiobookPlaybackPositionDelegate {
    func postListeningPosition(at location: String, completion: ((_ serverID: String?) -> Void)?)
}

@objc public protocol AudiobookBookmarkDelegate {
    func saveListeningPosition(at location: ChapterLocation, completion: ((_ serverID: String?) -> Void)?)
    func saveBookmark(at location: ChapterLocation, completion: ((_ location: ChapterLocation?) -> Void)?)
    func deleteBookmark(at location: ChapterLocation, completion: ((Bool) -> Void)?)
    func fetchBookmarks(completion: @escaping ([PalaceAudiobookToolkit.ChapterLocation]) -> Void)
}

@objc public protocol AudiobookManagerTimerDelegate {
    func audiobookManager(_ audiobookManager: AudiobookManager, didUpdate timer: Timer?)
}

/// Optionally pass in a function that forwards errors or other notable events
/// above a certain log level in a release build.
var sharedLogHandler: LogHandler?

private var waitingForPlayer: Bool = false

/// AudiobookManager is the main class for bringing Audiobook Playback to clients.
/// It is intended to be used by the host app to initiate downloads,
/// access the player, and manage the filesystem.
/// This object also manages the remote playback/media info for control
/// center / airplay.
@objc public protocol AudiobookManager {
    var refreshDelegate: RefreshDelegate? { get set }
    var playbackPositionDelegate: AudiobookPlaybackPositionDelegate? { get set }
    var bookmarkDelegate: AudiobookBookmarkDelegate? { get set }
    var timerDelegate: AudiobookManagerTimerDelegate? { get set }

    var networkService: AudiobookNetworkService { get }
    var metadata: AudiobookMetadata { get }
    var audiobook: Original_Audiobook { get }

    var tableOfContents: AudiobookTableOfContents { get }
    var sleepTimer: SleepTimer { get }
    var audiobookBookmarks: [ChapterLocation] { get }
    var timer: Timer? { get }

    static func setLogHandler(_ handler: @escaping LogHandler)
    func saveLocation()
    func saveBookmark(completion: @escaping (Error?) -> Void)
    func fetchBookmarks(completion: (([ChapterLocation]) -> Void)?)
    func deleteBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void)
    var playbackCompletionHandler: (() -> ())? { get set }
}

enum BookmarkError: Error {
    case bookmarkAlreadyExists
    case bookmarkFailedToSave
    
    var localizedDescription: String {
        switch self {
        case .bookmarkAlreadyExists:
            return Strings.Error.bookmarkAlreadyExistsError
        case .bookmarkFailedToSave:
            return Strings.Error.failedToSaveBookmarkError
        }
    }
}

/// Implementation of the AudiobookManager intended for use by clients. Also intended
/// to be used by the AudibookDetailViewController to respond to UI events.
@objcMembers public final class DefaultAudiobookManager: NSObject, AudiobookManager {
    public weak var timerDelegate: AudiobookManagerTimerDelegate?
    weak var tocDelegate: AudiobookTableOfContentsDelegate?
    public weak var refreshDelegate: RefreshDelegate?
    public weak var playbackPositionDelegate: AudiobookPlaybackPositionDelegate?
    public weak var bookmarkDelegate: AudiobookBookmarkDelegate?
    public var audiobookBookmarks: [ChapterLocation] = []
    private var playbackTrackerDelegate: AudiobookPlaybackTrackerDelegate?

    static public func setLogHandler(_ handler: @escaping LogHandler) {
        sharedLogHandler = handler
    }
    public var playbackCompletionHandler: (() -> ())?

    public private(set) var networkService: AudiobookNetworkService
    public let metadata: AudiobookMetadata
    public let audiobook: Original_Audiobook

    public static let skipTimeInterval: TimeInterval = 30
    
    public var tableOfContents: AudiobookTableOfContents {
        return AudiobookTableOfContents(
            networkService: self.networkService,
            player: self.audiobook.player
        )
    }

    /// The SleepTimer may be used to schedule playback to stop at a specific
    /// time. When a sleep timer is scheduled through the `setTimerTo:trigger`
    /// method, it must be retained so that it can properly pause the `player`.
    /// SleepTimer is thread safe, and will block until it can ensure only one
    /// object is messaging it at a time.
    public lazy var sleepTimer: SleepTimer = {
        return SleepTimer(player: self.audiobook.player)
    }()

    private(set) public var timer: Timer?
    private let mediaControlHandler: MediaControlHandler
    public init (metadata: AudiobookMetadata, audiobook: Original_Audiobook, networkService: AudiobookNetworkService, playbackTrackerDelegate: AudiobookPlaybackTrackerDelegate? = nil) {
        self.metadata = metadata
        self.audiobook = audiobook
        self.networkService = networkService
        self.playbackTrackerDelegate = playbackTrackerDelegate
        self.mediaControlHandler = MediaControlHandler(
            togglePlaybackHandler: { (_) -> MPRemoteCommandHandlerStatus in
                if audiobook.player.isPlaying {
                    audiobook.player.pause()
                } else {
                    audiobook.player.play()
                }
                return .success
        }, skipForwardHandler: { (_) -> MPRemoteCommandHandlerStatus in
            guard !waitingForPlayer || audiobook.player.queuesEvents else { return .success }
            waitingForPlayer = true
            audiobook.player.skipPlayhead(DefaultAudiobookManager.skipTimeInterval, completion: nil)
            return .success
        }, skipBackHandler: { (_) -> MPRemoteCommandHandlerStatus in
            guard !waitingForPlayer || audiobook.player.queuesEvents else { return .success }
            waitingForPlayer = true
            audiobook.player.skipPlayhead(-DefaultAudiobookManager.skipTimeInterval, completion: nil)
            return .success
        }, playbackRateHandler: { (rateEvent) -> MPRemoteCommandHandlerStatus in
            guard let mpRateCommand = rateEvent as? MPChangePlaybackRateCommandEvent else {
                ATLog(.error, "MPRemoteCommand could not cast to playback rate event.")
                return .commandFailed
            }
            let intValue = Int(mpRateCommand.playbackRate * 100)
            guard let playbackRate = PlaybackRate(rawValue: intValue) else {
                if (intValue < 100) && (intValue >= 50) {
                    audiobook.player.playbackRate = .threeQuartersTime
                    return .success
                } else {
                    audiobook.player.playbackRate = .normalTime
                    ATLog(.error, "Failed to create PlaybackRate from rawValue: \(intValue)")
                    return .commandFailed
                }
            }
            audiobook.player.playbackRate = playbackRate
            ATLog(.debug, "Media Control changed playback rate: float:\(mpRateCommand.playbackRate) int:\(playbackRate.rawValue)")
            return .success
        })
        super.init()
        self.audiobook.player.registerDelegate(self)
        self.fetchBookmarks()
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(DefaultAudiobookManager.timerDidTick1Second(_:)),
                userInfo: nil,
                repeats: true
            )
        }
    }

    deinit {
        ATLog(.debug, "DefaultAudiobookManager is deinitializing.")
    }

    public convenience init(metadata: AudiobookMetadata, audiobook: Original_Audiobook, playbackTrackerDelegate: AudiobookPlaybackTrackerDelegate? = nil) {
        self.init(
            metadata: metadata,
            audiobook: audiobook,
            networkService: DefaultAudiobookNetworkService(spine: audiobook.spine),
            playbackTrackerDelegate: playbackTrackerDelegate
        )
    }

    @objc func timerDidTick1Second(_ timer: Timer) {
        self.timerDelegate?.audiobookManager(self, didUpdate: timer)
        guard self.audiobook.player.isLoaded else { return }
        if let chapter = self.audiobook.player.currentChapterLocation {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
            if let title = chapter.title {
                info[MPMediaItemPropertyTitle] = title
            }
            info[MPMediaItemPropertyArtist] = self.metadata.title
            info[MPMediaItemPropertyAlbumTitle] = self.metadata.authors?.joined(separator: ", ")
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = chapter.playheadOffset
            info[MPMediaItemPropertyPlaybackDuration] = chapter.duration
            var rate = NSNumber(value: PlaybackRate.convert(rate: self.audiobook.player.playbackRate))
            if self.audiobook.player.playbackRate == .threeQuartersTime {
                // Map to visible rates on Apple Watch interface [0.5, 1.0, 1.5, 2.0]
                rate = NSNumber(value: 0.5)
            }
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
    
    public func updateAudiobook(with spine: [SpineElement]) {
        self.networkService = DefaultAudiobookNetworkService(spine: spine)
    }
    
    public func saveLocation()  {
        guard let location = audiobook.player.currentChapterLocation else {
            return
        }

        bookmarkDelegate?.saveListeningPosition(at: location) {
            guard let _ = $0 else {
                ATLog(.error, "Failed to post current location.")
                return
            }
        }
    }
    
    public func deleteBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void) {
        bookmarkDelegate?.deleteBookmark(at: location, completion: { [weak self] success in
            self?.audiobookBookmarks.removeAll(where: { $0.isSimilar(to: location) })
            completion(success)
        })
    }

    public func saveBookmark(completion: @escaping (Error?) -> Void) {
        guard audiobookBookmarks.first(where: { $0.isSimilar(to: audiobook.player.currentChapterLocation) }) == nil else {
            completion(BookmarkError.bookmarkAlreadyExists)
            return
        }

        guard let currentLocation = audiobook.player.currentChapterLocation else {
            ATLog(.error, "Failed to save to post bookmark at current location.")
            completion(BookmarkError.bookmarkFailedToSave)
            return
        }

        bookmarkDelegate?.saveBookmark(at: currentLocation, completion: { location in
            if let savedLocation = location {
                self.audiobookBookmarks.append(savedLocation)
                completion(nil)
            }
        })
    }

    public func fetchBookmarks(completion: (([ChapterLocation]) -> Void)? = nil) {
        bookmarkDelegate?.fetchBookmarks { [weak self] bookmarks in
            self?.audiobookBookmarks = bookmarks.sorted {
                let formatter = ISO8601DateFormatter()
                guard let date1 = formatter.date(from: $0.lastSavedTimeStamp),
                      let date2 = formatter.date(from: $1.lastSavedTimeStamp)
                else {
                    return false
                }
                return date1 > date2
            }
            
            completion?(self?.audiobookBookmarks ?? [])
        }
    }
}

extension DefaultAudiobookManager: PlayerDelegate {
    public func player(_ player: Player, didBeginPlaybackOf chapter: ChapterLocation) {
        waitingForPlayer = false
        self.mediaControlHandler.enableMediaControlCommands()
        playbackTrackerDelegate?.playbackStarted()
    }
    public func player(_ player: Player, didStopPlaybackOf chapter: ChapterLocation) {
        waitingForPlayer = false
        playbackTrackerDelegate?.playbackStopped()
    }
    public func player(_ player: Player, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?) {
        playbackTrackerDelegate?.playbackStopped()
    }
    public func player(_ player: Player, didComplete chapter: ChapterLocation) {
        waitingForPlayer = false
        playbackTrackerDelegate?.playbackStopped()

        let sortedSpine = self.networkService.spine.map{ $0.chapter }.sorted{ $0 < $1 }
        guard let firstChapter = sortedSpine.first,
              let lastChapter = sortedSpine.last else {
            ATLog(.error, "Audiobook Spine is corrupt.")
            return
        }
        if lastChapter.inSameChapter(other: chapter) {
            self.playbackCompletionHandler?()
            self.audiobook.player.movePlayheadToLocation(firstChapter) { _ in
                self.audiobook.player.pause()
            }
        }
    }
    public func playerDidUnload(_ player: Player) {
        self.mediaControlHandler.teardown()
        self.timer?.invalidate()
        playbackTrackerDelegate?.playbackStopped()
    }
}

typealias RemoteCommandHandler = (_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus

private class MediaControlHandler {

    private var commandsHaveBeenEnabled = false
    private let togglePlaybackHandler: RemoteCommandHandler
    private let skipForwardHandler: RemoteCommandHandler
    private let skipBackHandler: RemoteCommandHandler
    private let playbackRateHandler: RemoteCommandHandler
    private let commandCenter = MPRemoteCommandCenter.shared()

    func enableMediaControlCommands() {
        if !self.commandsHaveBeenEnabled {
            self.commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: DefaultAudiobookManager.skipTimeInterval)]
            self.commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: DefaultAudiobookManager.skipTimeInterval)]

            var rates = [NSNumber]()
            for playbackRate in PlaybackRate.allCases {
                let floatRate = PlaybackRate.convert(rate: playbackRate)
                rates.append(NSNumber(value: floatRate))
            }

            ATLog(.debug, "Setting Supported Playback Rates: \(rates)")
            self.commandCenter.changePlaybackRateCommand.supportedPlaybackRates = rates
            self.setMediaControlCommands(enabled: true)
            self.commandsHaveBeenEnabled = true
        }
    }

    func teardown() {
        //Per Apple's doc comment, specifying to nil removes all targets.
        self.commandCenter.playCommand.removeTarget(nil)
        self.commandCenter.pauseCommand.removeTarget(nil)
        self.commandCenter.togglePlayPauseCommand.removeTarget(nil)
        self.commandCenter.skipForwardCommand.removeTarget(nil)
        self.commandCenter.skipBackwardCommand.removeTarget(nil)
        self.commandCenter.changePlaybackRateCommand.removeTarget(nil)
        self.setMediaControlCommands(enabled: false)
        if (MPNowPlayingInfoCenter.default().nowPlayingInfo != nil) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
    
    init(togglePlaybackHandler: @escaping RemoteCommandHandler,
         skipForwardHandler: @escaping RemoteCommandHandler,
         skipBackHandler: @escaping RemoteCommandHandler,
         playbackRateHandler: @escaping RemoteCommandHandler) {
        self.togglePlaybackHandler = togglePlaybackHandler
        self.skipForwardHandler = skipForwardHandler
        self.skipBackHandler = skipBackHandler
        self.playbackRateHandler = playbackRateHandler
        self.commandCenter.togglePlayPauseCommand.addTarget(handler: self.togglePlaybackHandler)
        self.commandCenter.playCommand.addTarget(handler: self.togglePlaybackHandler)
        self.commandCenter.pauseCommand.addTarget(handler: self.togglePlaybackHandler)
        self.commandCenter.skipForwardCommand.addTarget(handler: self.skipForwardHandler)
        self.commandCenter.skipBackwardCommand.addTarget(handler: self.skipBackHandler)
        self.commandCenter.changePlaybackRateCommand.addTarget(handler: self.playbackRateHandler)
    }

    deinit {
        ATLog(.debug, "MediaControlHandler is deinitializing.")
    }

    private func setMediaControlCommands(enabled: Bool) {
        ATLog(.debug, "MediaControlHandler commands toggled to \(enabled)")
        self.commandCenter.playCommand.isEnabled = enabled
        self.commandCenter.pauseCommand.isEnabled = enabled
        self.commandCenter.togglePlayPauseCommand.isEnabled = enabled
        self.commandCenter.skipForwardCommand.isEnabled = enabled
        self.commandCenter.skipBackwardCommand.isEnabled = enabled
        self.commandCenter.changePlaybackRateCommand.isEnabled = enabled
    }
}
