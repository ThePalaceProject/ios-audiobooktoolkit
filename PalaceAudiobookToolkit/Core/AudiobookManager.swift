//
//  AudiobookManager.swift
//  PalaceAudibookKit
//
//

import Combine
import AVFoundation
import MediaPlayer

public enum AudiobookManagerState {
    case positionUpdated(TrackPosition?)
    case refreshRequested
    case locationPosted(String?)
    case bookmarkSaved(TrackPosition?, Error?)
    case bookmarksFetched([TrackPosition])
    case bookmarkDeleted(Bool)
    case playbackBegan(TrackPosition)
    case playbackStopped(TrackPosition)
    case playbackFailed(TrackPosition?)
    case playbackCompleted(TrackPosition)
    case playbackUnloaded
    case decrypting
    case overallDownloadProgress(Float)
    case error((any Track)?, Error?)
}

public protocol AudiobookBookmarkDelegate {
    func saveListeningPosition(at location: TrackPosition, completion: ((_ serverID: String?) -> Void)?)
    func saveBookmark(at location: TrackPosition, completion: ((_ location: TrackPosition?) -> Void)?)
    func deleteBookmark(at location: TrackPosition, completion: ((Bool) -> Void)?)
    func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void)
}

public protocol AudiobookManager {
    typealias SaveBookmarkResult = Result<TrackPosition, BookmarkError>

    var bookmarkDelegate: AudiobookBookmarkDelegate? { get }
    var networkService: AudiobookNetworkService { get }
    var metadata: AudiobookMetadata { get }
    var audiobook: Audiobook { get }
    var bookmarks: [TrackPosition] { get }
    var needsDownloadRetry: Bool { get }

    var sleepTimer: SleepTimer { get }
    var audiobookBookmarksPublisher: CurrentValueSubject<[TrackPosition], Never> { get }

    var currentOffset: Double { get }
    var currentDuration: Double { get }
    var totalDuration: Double { get }
    var currentChapter: Chapter? { get }

    static func setLogHandler(_ handler: @escaping LogHandler)

    func play()
    func pause()
    func unload()
    func downloadProgress(for chapter: Chapter) -> Double
    func retryDownload()

    @discardableResult func saveLocation(_ location: TrackPosition) -> Result<Void, Error>?
    func saveBookmark(at location: TrackPosition, completion: ((_ result: SaveBookmarkResult) -> Void)?)
    func deleteBookmark(at location: TrackPosition, completion: ((Bool) -> Void)?)
    func fetchBookmarks(completion: (([TrackPosition]) -> Void)?)

    var statePublisher: PassthroughSubject<AudiobookManagerState, Never> { get }

    var playbackCompletionHandler: (() -> Void)? { get set }
}

public enum BookmarkError: Error {
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

var sharedLogHandler: LogHandler?

public final class DefaultAudiobookManager: NSObject, AudiobookManager {
    private var waitingForPlayer: Bool = false
    public var bookmarkDelegate: AudiobookBookmarkDelegate?

    public var metadata: AudiobookMetadata
    public var audiobook: Audiobook
    public var networkService: AudiobookNetworkService
    public var bookmarks: [TrackPosition] = []

    private var cancellables = Set<AnyCancellable>()
    public var statePublisher = PassthroughSubject<AudiobookManagerState, Never>()
    public var audiobookBookmarksPublisher = CurrentValueSubject<[TrackPosition], Never>([])
    private var mediaControlPublisher: MediaControlPublisher
    private var playbackTrackerDelegate: AudiobookPlaybackTrackerDelegate?
    public var playbackCompletionHandler: (() -> ())?

    public static let skipTimeInterval: TimeInterval = 30

    public var tableOfContents: AudiobookTableOfContents {
        audiobook.tableOfContents
    }

    public var currentOffset: Double {
        audiobook.player.currentOffset
    }

    public var currentDuration: Double {
        currentChapter?.duration ?? audiobook.player.currentTrackPosition?.track.duration ?? 0.0
    }

    public var totalDuration: Double {
        audiobook.tableOfContents.tracks.totalDuration
    }

    public var currentChapter: Chapter? {
        audiobook.player.currentChapter
    }

    public lazy var sleepTimer: SleepTimer = {
        SleepTimer(player: self.audiobook.player)
    }()

    public var needsDownloadRetry: Bool = false

    private(set) public var timer: Cancellable?

    // MARK: - Initialization

    public init(
        metadata: AudiobookMetadata,
        audiobook: Audiobook,
        networkService: AudiobookNetworkService,
        playbackTrackerDelegate: AudiobookPlaybackTrackerDelegate? = nil
    ) {
        self.metadata = metadata
        self.audiobook = audiobook
        self.networkService = networkService
        self.playbackTrackerDelegate = playbackTrackerDelegate
        self.mediaControlPublisher = MediaControlPublisher()

        super.init()
        setupBindings()
        subscribeToPlayer()
        setupNowPlayingInfoTimer()
        subscribeToMediaControlCommands()
        calculateOverallDownloadProgress()
    }


    public static func setLogHandler(_ handler: @escaping LogHandler) {
        sharedLogHandler = handler
    }

    // MARK: - Setup Bindings

    private func setupBindings() {
        networkService.downloadStatePublisher
            .sink { [weak self] downloadState in
                guard let self = self else { return }
                switch downloadState {
                case .error(let track, let error):
                    self.statePublisher.send(.error(track, error))
                case .downloadComplete:
                    self.checkIfRetryIsNeeded()
                default:
                    break
                }
                self.calculateOverallDownloadProgress()
            }
            .store(in: &cancellables)
    }

    private func checkIfRetryIsNeeded() {
        needsDownloadRetry = audiobook.tableOfContents.allTracks.contains { $0.downloadTask?.needsRetry ?? false }
    }

    private func calculateOverallDownloadProgress() {
        let tracks = audiobook.tableOfContents.allTracks
        let totalProgress = tracks.compactMap { $0.downloadTask?.downloadProgress }.reduce(0, +)
        let overallProgress = totalProgress / Float(tracks.count)
        statePublisher.send(.overallDownloadProgress(overallProgress))
    }

    // MARK: - Now Playing Info

    private func setupNowPlayingInfoTimer() {
        timer?.cancel()
        timer = nil

        let interval: TimeInterval = UIApplication.shared.applicationState == .active ? 1 : 100
        playbackTrackerDelegate?.playbackStarted()

        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { [weak self] _ in self?.audiobook.player.currentTrackPosition }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                guard let self = self else { return }
                self.statePublisher.send(.positionUpdated(position))
                self.updateNowPlayingInfo(position)
            }
    }

    private func updateNowPlayingInfo(_ position: TrackPosition?) {
        guard let currentTrackPosition = position else { return }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = (try? tableOfContents.chapter(forPosition: currentTrackPosition).title) ?? currentTrackPosition.track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = metadata.title
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata.authors?.joined(separator: ", ")
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTrackPosition.timestamp
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = currentTrackPosition.track.duration

        let playbackRate = PlaybackRate.convert(rate: audiobook.player.playbackRate)
        let isPlaying = audiobook.player.isPlaying
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Audiobook Actions

    public func downloadProgress(for chapter: Chapter) -> Double {
        tableOfContents.downloadProgress(for: chapter)
    }

    public func retryDownload() {
        needsDownloadRetry = false
        networkService.fetchUndownloadedTracks()
    }

    public func play() {
        playbackTrackerDelegate?.playbackStarted()
        audiobook.player.play()
    }

    public func pause() {
        playbackTrackerDelegate?.playbackStopped()
        audiobook.player.pause()
    }

    public func unload() {
        playbackTrackerDelegate?.playbackStopped()
        audiobook.player.unload()
        networkService.cleanup()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        cancellables.removeAll()
    }

    @discardableResult
    public func saveLocation(_ location: TrackPosition) -> Result<Void, Error>? {
        var result: Result<Void, Error>? = nil

        bookmarkDelegate?.saveListeningPosition(at: location) { serverId in
            if let _ = serverId {
                result = .success(())
            } else {
                result = .failure(NSError(domain: OpenAccessPlayerErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to post current location."]))
                ATLog(.error, "Failed to post current location.")
            }
        }
        return result
    }

    public func saveBookmark(at location: TrackPosition, completion: ((_ result: SaveBookmarkResult) -> Void)?) {
        guard bookmarks.first(where: { $0 == location }) == nil else {
            ATLog(.error, "Bookmark already saved")
            completion?(.failure(.bookmarkAlreadyExists))
            return
        }

        bookmarkDelegate?.saveBookmark(at: location) { [weak self] savedLocation in
            guard let savedLocation = savedLocation else {
                completion?(.failure(.bookmarkFailedToSave))
                return
            }
            self?.bookmarks.append(savedLocation)
            completion?(.success(savedLocation))
        }
    }

    public func deleteBookmark(at location: TrackPosition, completion: ((Bool) -> Void)?) {
        bookmarkDelegate?.deleteBookmark(at: location) { [weak self] success in
            guard success else {
                completion?(false)
                return
            }

            self?.bookmarks.removeAll { $0 == location }
            completion?(true)
        }
    }

    public func fetchBookmarks(completion: (([TrackPosition]) -> Void)? = nil) {
        bookmarkDelegate?.fetchBookmarks(for: audiobook.tableOfContents.tracks, toc: audiobook.tableOfContents.toc) { [weak self] bookmarks in
            self?.bookmarks = bookmarks.sorted {
                let formatter = ISO8601DateFormatter()
                guard let date1 = formatter.date(from: $0.lastSavedTimeStamp),
                      let date2 = formatter.date(from: $1.lastSavedTimeStamp) else {
                    return false
                }
                return date1 > date2
            }

            completion?(self?.bookmarks ?? [])
        }
    }

    // MARK: - Player Subscription

    private func subscribeToPlayer() {
        audiobook.player.playbackStatePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] playbackState in
                guard let self = self else { return }

                switch playbackState {
                case .started(let trackPosition):
                    self.handlePlaybackBegan(trackPosition)

                case .stopped(let trackPosition):
                    self.handlePlaybackStopped(trackPosition)

                case .failed(let trackPosition, let error):
                    self.handlePlaybackFailed(trackPosition, error: error)

                case .completed(let chapter):
                    self.handlePlaybackCompleted(chapter)

                case .unloaded:
                    self.handlePlayerUnloaded()
                    
                case .decrypting:
                    return
                case .bookCompleted:
                    self.playbackCompletionHandler?()
                }
            }
            .store(in: &cancellables)
    }

    private func handlePlaybackBegan(_ trackPosition: TrackPosition) {
        waitingForPlayer = false
        statePublisher.send(.playbackBegan(trackPosition))
        playbackTrackerDelegate?.playbackStarted()
    }

    private func handlePlaybackStopped(_ trackPosition: TrackPosition) {
        waitingForPlayer = false
        statePublisher.send(.playbackStopped(trackPosition))
        playbackTrackerDelegate?.playbackStopped()
    }

    private func handlePlaybackFailed(_ trackPosition: TrackPosition?, error: Error?) {
        statePublisher.send(.playbackFailed(trackPosition))
        playbackTrackerDelegate?.playbackStopped()
    }

    private func handlePlaybackCompleted(_ chapter: Chapter) {
        waitingForPlayer = false
        statePublisher.send(.playbackStopped(chapter.position))
    }

    private func handlePlayerUnloaded() {
        playbackTrackerDelegate?.playbackStopped()
        mediaControlPublisher.tearDown()
        timer?.cancel()
        statePublisher.send(.playbackUnloaded)
    }

    // MARK: - Media Control Commands

    private func subscribeToMediaControlCommands() {
        mediaControlPublisher.commandPublisher
            .sink { [weak self] command in
                guard let self = self else { return }
                switch command {
                case .playPause:
                    self.audiobook.player.isPlaying == true ? self.audiobook.player.pause() : self.audiobook.player.play()
                case .skipForward:
                    self.audiobook.player.skipPlayhead(DefaultAudiobookManager.skipTimeInterval, completion: nil)
                case .skipBackward:
                    self.audiobook.player.skipPlayhead(-DefaultAudiobookManager.skipTimeInterval, completion: nil)
                case .changePlaybackRate(let rate):
                    if let playbackRate = PlaybackRate(rawValue: Int(rate * 100)) {
                        self.audiobook.player.playbackRate = playbackRate
                    }
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        ATLog(.debug, "DefaultAudiobookManager is deinitializing.")
        timer?.cancel()
        timer = nil
        cancellables.removeAll()
    }
}
