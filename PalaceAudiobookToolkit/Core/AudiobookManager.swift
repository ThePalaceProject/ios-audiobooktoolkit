//
//  AudiobookManager.swift
//  NYPLAudibookKit
//
//  Created by Dean Silfen on 1/12/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Combine
import AVFoundation
import MediaPlayer

public enum AudiobookManagerState {
    case timerUpdated(AudiobookManager, Timer?)
    case refreshRequested
    case locationPosted(String?)
    case bookmarkSaved(TrackPosition?, Error?)
    case bookmarksFetched([TrackPosition])
    case bookmarkDeleted(Bool)
    case playbackBegan(TrackPosition)
    case playbacStopped(TrackPosition)
    case playbackFailed(TrackPosition?)
    case playbackCompleted(TrackPosition)
    case playbackUnloaded
    case error(Track?, Error?)
}

public enum AudiobookManagerAction {
    case saveLocation(location: TrackPosition)
    case saveBookmark(bookmark: TrackPosition)
    case deleteBookmark(bookmark: TrackPosition)
    case fetchBookmarks
}

/// Optionally pass in a function that forwards errors or other notable events
/// above a certain log level in a release build.
var sharedLogHandler: LogHandler?

private var waitingForPlayer: Bool = false

public protocol AudiobookManager {
    var networkService: AudiobookNetworkService { get }
    var metadata: AudiobookMetadata { get }
    var audiobook: Audiobook { get }
    
    var sleepTimer: SleepTimer { get }
    var audiobookBookmarksPublisher: CurrentValueSubject<[TrackPosition], Never> { get }

    static func setLogHandler(_ handler: @escaping LogHandler)
    
    func saveLocation() -> Result<Void, Error>?
    func saveBookmark(location: TrackPosition) -> Result<TrackPosition?, Error>
    func deleteBookmark(at location: TrackPosition) -> Bool
    
    var statePublisher: PassthroughSubject<AudiobookManagerState, Never> { get }
    var actionPublisher: PassthroughSubject<AudiobookManagerAction, Never> { get }
    
    var playbackCompletionHandler: (() -> Void)? { get set }
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
public final class DefaultAudiobookManager: NSObject, AudiobookManager {
    public var actionPublisher = PassthroughSubject<AudiobookManagerAction, Never>()
    
    public var metadata: AudiobookMetadata
    public var audiobook: Audiobook
    public var networkService: AudiobookNetworkService
    
    private var cancellables = Set<AnyCancellable>()
    public var statePublisher = PassthroughSubject<AudiobookManagerState, Never>()
    public var audiobookBookmarksPublisher = CurrentValueSubject<[TrackPosition], Never>([])
    private var mediaControlPublisher: MediaControlPublisher

    public var playbackCompletionHandler: (() -> ())?
    public static let skipTimeInterval: TimeInterval = 30
    
    public var tableOfContents: DeprecatedAudiobookTableOfContents {
        return DeprecatedAudiobookTableOfContents(
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

    public init(metadata: AudiobookMetadata, audiobook: Audiobook, networkService: AudiobookNetworkService) {
        self.metadata = metadata
        self.audiobook = audiobook
        self.networkService = networkService
        self.mediaControlPublisher = MediaControlPublisher()

        super.init()
        setupBindings()
        subscribeToPlayer()
        setupNowPlayingInfoTimer()
        subscribeToMediaControlCommands()
    }
    
    static public func setLogHandler(_ handler: @escaping LogHandler) {
        sharedLogHandler = handler
    }
    
    private func setupBindings() {
        networkService.downloadStatePublisher
            .sink { [weak self] downloadState in
                switch downloadState {
                case .error(let track, let error):
                    self?.statePublisher.send(.error(track, error))
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupNowPlayingInfoTimer() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(self.timerDidTick1Second(_:)),
                userInfo: nil,
                repeats: true
            )
        }
    }

    deinit {
        ATLog(.debug, "DefaultAudiobookManager is deinitializing.")
    }

    @objc func timerDidTick1Second(_ timer: Timer) {
        updateNowPlayingInfo()
    }
    
    private func updateNowPlayingInfo() {
        guard let currentTrackPosition = audiobook.player.currentTrackPosition else { return }
        
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTrackPosition.track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = self.metadata.title
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = self.metadata.authors?.joined(separator: ", ")
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentTrackPosition.timestamp) / 1000
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(currentTrackPosition.track.duration) / 1000
        let playbackRate = PlaybackRate.convert(rate: self.audiobook.player.playbackRate)
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = self.audiobook.player.isPlaying ? playbackRate : 0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    public func updateAudiobook(with tracks: [Track]) {
        self.networkService = DefaultAudiobookNetworkService(tracks: tracks)
    }

    public func saveLocation() -> Result<Void, any Error>? {
        guard let location = audiobook.player.currentTrackPosition else {
            return nil
        }
        

        print("Save Location here: \(location)")
        return nil
//        bookmarkDelegate?.saveListeningPosition(at: location) {
//            guard let _ = $0 else {
//                ATLog(.error, "Failed to post current location.")
//                return
//            }
//        }
    }

    public func deleteBookmark(at location: TrackPosition) -> Bool {
        print("Delete Location here: \(location)")
        return true

//        bookmarkDelegate?.deleteBookmark(at: location, completion: { [weak self] success in
//            self?.audiobookBookmarks.removeAll(where: { $0.isSimilar(to: location) })
//            completion(success)
//        })
    }

    public func saveBookmark(location: TrackPosition) -> Result<TrackPosition?, any Error> {
        print("Save bookmark here")
        return .success(nil)
//        guard audiobookBookmarks.first(where: { $0.isSimilar(to: audiobook.player.currentChapterLocation) }) == nil else {
//            completion(BookmarkError.bookmarkAlreadyExists)
//            return
//        }
//
//        guard let currentLocation = audiobook.player.currentChapterLocation else {
//            ATLog(.error, "Failed to save to post bookmark at current location.")
//            completion(BookmarkError.bookmarkFailedToSave)
//            return
//        }
//
//        bookmarkDelegate?.saveBookmark(at: currentLocation, completion: { location in
//            if let savedLocation = location {
//                self.audiobookBookmarks.append(savedLocation)
//                completion(nil)
//            }
//        })
    }

    public func fetchBookmarks(completion: (([TrackPosition]) -> Void)? = nil) {
        completion?([])
//        bookmarkDelegate?.fetchBookmarks { [weak self] bookmarks in
//            self?.audiobookBookmarks = bookmarks.sorted {
//                let formatter = ISO8601DateFormatter()
//                guard let date1 = formatter.date(from: $0.lastSavedTimeStamp),
//                      let date2 = formatter.date(from: $1.lastSavedTimeStamp)
//                else {
//                    return false
//                }
//                return date1 > date2
//            }
//            
//            completion?(self?.audiobookBookmarks ?? [])
//        }
    }
}

extension DefaultAudiobookManager {
    private func subscribeToPlayer() {
        audiobook.player.playbackStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] playbackState in
                guard let self else { return }

                switch playbackState {
                case .began(let trackPosition):
                    self.handlePlaybackBegan(trackPosition)
                    
                case .stopped(let trackPosition):
                    self.handlePlaybackStopped(trackPosition)
                    
                case .failed(let trackPosition, let error):
                    self.handlePlaybackFailed(trackPosition, error: error)
                    
                case .completed(let chapter):
                    self.handlePlaybackCompleted(chapter)
                    
                case .unloaded:
                    self.handlePlayerUnloaded()
                }
            }
            .store(in: &cancellables)
    }

    private func handlePlaybackBegan(_ trackPosition: TrackPosition) {
        waitingForPlayer = false
        statePublisher.send(.playbackBegan(trackPosition))
    }
    
    private func handlePlaybackStopped(_ trackPosition: TrackPosition) {
        waitingForPlayer = false
        statePublisher.send(.playbacStopped(trackPosition))
    }
    
    private func handlePlaybackFailed(_ trackPosition: TrackPosition?, error: Error) {
        statePublisher.send(.playbackFailed(trackPosition))
    }
    
    private func handlePlaybackCompleted(_ chapter: Chapter) {
        waitingForPlayer = false
        statePublisher.send(.playbacStopped(chapter.position))
    }
    
    private func handlePlayerUnloaded() {
        mediaControlPublisher.tearDown()
        timer?.invalidate()
        statePublisher.send(.playbackUnloaded)
    }
}

extension DefaultAudiobookManager {
    private func subscribeToMediaControlCommands() {
        mediaControlPublisher.commandPublisher
            .sink { [weak self] command in
                switch command {
                case .playPause:
                    if self?.audiobook.player.isPlaying == true {
                        self?.audiobook.player.pause()
                    } else {
                        self?.audiobook.player.play()
                    }
                case .skipForward:
                    self?.audiobook.player.skipPlayhead(DefaultAudiobookManager.skipTimeInterval, completion: nil)
                case .skipBackward:
                    self?.audiobook.player.skipPlayhead(-DefaultAudiobookManager.skipTimeInterval, completion: nil)
                case .changePlaybackRate(let rate):
                    if let playbackRate = PlaybackRate(rawValue: Int(rate * 100)) {
                        self?.audiobook.player.playbackRate = playbackRate
                    }
                }
            }
            .store(in: &cancellables)
    }
}
