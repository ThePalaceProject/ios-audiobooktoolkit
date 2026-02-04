//
//  AudiobookManager.swift
//  PalaceAudibookKit
//
//

import AVFoundation
import Combine
import MediaPlayer

// MARK: - AudiobookManagerState

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
  case overallDownloadProgress(Float)
  case error((any Track)?, Error?)
}

// MARK: - AudiobookBookmarkDelegate

public protocol AudiobookBookmarkDelegate {
  func saveListeningPosition(at location: TrackPosition, completion: ((_ serverID: String?) -> Void)?)
  func saveBookmark(at location: TrackPosition, completion: ((_ location: TrackPosition?) -> Void)?)
  func deleteBookmark(at location: TrackPosition, completion: ((Bool) -> Void)?)
  func fetchBookmarks(for tracks: Tracks, toc: [Chapter], completion: @escaping ([TrackPosition]) -> Void)
  
  func flushPendingOperations()
  func saveListeningPositionSync(at position: TrackPosition)
}

// MARK: - AudiobookManager

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

  func updateNowPlayingInfo(_ position: TrackPosition?)

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

// MARK: - BookmarkError

public enum BookmarkError: Error {
  case bookmarkAlreadyExists
  case bookmarkFailedToSave

  var localizedDescription: String {
    switch self {
    case .bookmarkAlreadyExists:
      Strings.Error.bookmarkAlreadyExistsError
    case .bookmarkFailedToSave:
      Strings.Error.failedToSaveBookmarkError
    }
  }
}

var sharedLogHandler: LogHandler?

// MARK: - AudiobookPositionCalculator

/// Handles precise position calculations for all audiobook types
/// Supports multi-track chapters and complex timestamp structures
public class AudiobookPositionCalculator {
  public init() {}

  public func currentChapterOffset(from trackPosition: TrackPosition, chapter: Chapter) -> TimeInterval {
    do {
      let offset = try trackPosition - chapter.position
      return max(0.0, offset) // Ensure non-negative
    } catch {
      ATLog(.error, "Position calculation failed: \(error.localizedDescription)")
      return 0.0
    }
  }

  public func chapterProgress(from trackPosition: TrackPosition, chapter: Chapter) -> Double {
    let chapterDuration = chapter.duration ?? chapter.position.track.duration
    guard chapterDuration > 0 else {
      return 0.0
    }

    let chapterOffset = currentChapterOffset(from: trackPosition, chapter: chapter)
    return min(1.0, max(0.0, chapterOffset / chapterDuration))
  }

  public func validatePosition(_ position: TrackPosition, within chapter: Chapter) -> TrackPosition {
    let chapterStart = chapter.position.timestamp
    let chapterDuration = chapter.duration ?? chapter.position.track.duration
    let chapterEnd = chapterStart + chapterDuration
    let trackDuration = chapter.position.track.duration

    // Clamp within chapter and track boundaries
    let clampedTimestamp = min(position.timestamp, min(chapterEnd, trackDuration))
    let validTimestamp = max(chapterStart, clampedTimestamp)

    return TrackPosition(
      track: chapter.position.track,
      timestamp: validTimestamp,
      tracks: position.tracks
    )
  }

  public func calculateSeekPosition(sliderValue: Double, currentChapter: Chapter) -> TrackPosition {
    let chapterDuration = currentChapter.duration ?? currentChapter.position.track.duration
    let chapterStartTimestamp = currentChapter.position.timestamp

    // Calculate absolute position within track
    let offsetWithinChapter = sliderValue * chapterDuration
    let absoluteTimestamp = chapterStartTimestamp + offsetWithinChapter

    // Create position and validate boundaries
    let proposedPosition = TrackPosition(
      track: currentChapter.position.track,
      timestamp: absoluteTimestamp,
      tracks: currentChapter.position.tracks
    )

    return validatePosition(proposedPosition, within: currentChapter)
  }
}

// MARK: - DefaultAudiobookManager

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
  public var playbackCompletionHandler: (() -> Void)?

  public static let skipTimeInterval: TimeInterval = 30

  // MARK: - Enhanced Position System

  public let positionCalculator = AudiobookPositionCalculator()

  // MARK: - Enhanced Seeking Interface

  /// Enhanced seeking with precise multi-track chapter support
  public func seekWithSlider(value: Double, completion: @escaping (TrackPosition?) -> Void) {
    guard let currentChapter = currentChapter else {
      completion(nil)
      return
    }

    // Calculate seek position with multi-track chapter support
    let chapterDuration = currentChapter.duration ?? currentChapter.position.track.duration
    let offsetWithinChapter = value * chapterDuration

    // Use TrackPosition arithmetic to handle multi-track chapters correctly
    let basePosition = currentChapter.position
    let targetPosition = basePosition + offsetWithinChapter

    // Log seeking operation for debugging if needed
    #if DEBUG
    AudiobookLog.seeking(
      "SLIDER_SEEK",
      from: audiobook.player.currentTrackPosition,
      to: targetPosition,
      sliderValue: value,
      chapterTitle: currentChapter.title,
      success: true
    )
    #endif

    if let openAccessPlayer = audiobook.player as? OpenAccessPlayer {
      openAccessPlayer.seekTo(position: targetPosition) { adjustedPosition in
        completion(adjustedPosition)
      }
    } else {
        audiobook.player.play(at: targetPosition) { error in
            completion(error == nil ? targetPosition : nil)
        }
    }
  }

  /// Calculate chapter-relative progress for a given position
  public func calculateChapterProgress(for position: TrackPosition) -> Double {
    do {
      let chapter = try audiobook.tableOfContents.chapter(forPosition: position)
      return positionCalculator.chapterProgress(from: position, chapter: chapter)
    } catch {
      return 0.0
    }
  }

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

  public private(set) var timer: Cancellable?
  private var uiUpdateTimer: Cancellable?
  private var lastKnownChapter: Chapter?

  private var chapterMonitorTimer: Cancellable?

  // MARK: - Initialization

  public init(
    metadata: AudiobookMetadata,
    audiobook: Audiobook,
    networkService: AudiobookNetworkService,
    playbackTrackerDelegate: AudiobookPlaybackTrackerDelegate? = nil
  ) {
    self.metadata = metadata
    self.audiobook = audiobook
    // Modern position calculations integrated
    self.networkService = networkService
    self.playbackTrackerDelegate = playbackTrackerDelegate
    mediaControlPublisher = MediaControlPublisher()

    super.init()
    setupBindings()
    subscribeToPlayer()
    setupNowPlayingInfoTimer()
    setupChapterMonitorTimer()
    subscribeToMediaControlCommands()
    calculateOverallDownloadProgress()
    setupAppStateObserver()

    if let currentPosition = audiobook.player.currentTrackPosition {
      lastKnownChapter = try? tableOfContents.chapter(forPosition: currentPosition)
    }

    ATLog(.debug, "AudiobookManager initialized with enhanced position system and energy optimizations")
  }

  public static func setLogHandler(_ handler: @escaping LogHandler) {
    sharedLogHandler = handler
  }

  // MARK: - Setup Bindings

  private func setupAppStateObserver() {
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        guard let self = self else { return }
        ATLog(.debug, "⚡ App became active - restarting optimized timer and updating position")
        
        // Immediately capture and update current position for UI sync
        if let currentPosition = audiobook.player.currentTrackPosition {
          statePublisher.send(.positionUpdated(currentPosition))
          updateNowPlayingInfo(currentPosition)
          ATLog(.debug, "🔒 Immediately updated position on foreground: \(currentPosition.timestamp)")
        }
        
        setupNowPlayingInfoTimer()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
      .sink { [weak self] _ in
        guard let self = self else { return }
        ATLog(.debug, "⚡ App will resign active - saving current position")
        
        // Save position immediately before app goes to background
        if let currentPosition = audiobook.player.currentTrackPosition {
          saveLocation(currentPosition)
          ATLog(.debug, "🔒 Saved position on resign active: \(currentPosition.timestamp)")
        }
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      .sink { [weak self] _ in
        guard let self = self else { return }
        ATLog(.debug, "⚡ App entered background - pausing timer for energy savings")
        
        // Final position save when entering background
        if let currentPosition = audiobook.player.currentTrackPosition {
          saveLocation(currentPosition)
          ATLog(.debug, "🔒 Final position save on background: \(currentPosition.timestamp)")
        }
        
        timer?.cancel()
        timer = nil
      }
      .store(in: &cancellables)
    
    NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
      .sink { [weak self] _ in
        guard let self = self else { return }
        ATLog(.debug, "🚨 App will terminate - performing SYNCHRONOUS position save")
        
        if let currentPosition = audiobook.player.currentTrackPosition {
          bookmarkDelegate?.flushPendingOperations()
          bookmarkDelegate?.saveListeningPositionSync(at: currentPosition)
          ATLog(.debug, "🔒 CRITICAL: Saved position on app termination: \(currentPosition.timestamp)")
        }
      }
      .store(in: &cancellables)
  }

  private func setupBindings() {
    networkService.downloadStatePublisher
      .sink { [weak self] downloadState in
        guard let self = self else {
          return
        }
        switch downloadState {
        case let .error(track, error):
          statePublisher.send(.error(track, error))
        case .downloadComplete:
          checkIfRetryIsNeeded()
          // Ensure final 100% progress is sent
          statePublisher.send(.overallDownloadProgress(1.0))
        case let .overallProgress(progress):
          // Use the network service's calculated progress directly
          // This is more accurate as it uses the synchronized progressDictionary
          statePublisher.send(.overallDownloadProgress(progress))
        case .progress, .completed, .deleted:
          // Individual track events - network service will send overallProgress separately
          break
        }
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

    let appState = UIApplication.shared.applicationState
    let interval: TimeInterval

    switch appState {
    case .active:
      interval = 2.0 // Reduced from 1 second to 2 seconds (50% reduction)
    case .inactive:
      interval = 10.0 // Reduce frequency when inactive
    case .background:
      interval = 15.0 // Keep running but very infrequently for lock screen sync
      ATLog(.debug, "⚡ Timer running at 15s intervals for background lock screen updates")
    @unknown default:
      interval = 5.0
    }

    // Only start time tracking if player is actually playing
    // This prevents overcounting when setupNowPlayingInfoTimer() is called
    // during init or app foreground transitions while not playing
    if audiobook.player.isPlaying {
      playbackTrackerDelegate?.playbackStarted()
    }

    timer = Timer.publish(every: interval, on: .main, in: .common)
      .autoconnect()
      .receive(on: DispatchQueue.global(qos: .utility))
      .compactMap { [weak self] _ -> TrackPosition? in
        guard let self = self, audiobook.player.isPlaying else {
          return nil
        }
        return audiobook.player.currentTrackPosition
      }
      .removeDuplicates { oldPosition, newPosition in
        abs(oldPosition.timestamp - newPosition.timestamp) < 0.5
      }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] position in
        guard let self = self else {
          return
        }

        if let currentChapter = try? tableOfContents.chapter(forPosition: position) {
          if lastKnownChapter?.title != currentChapter.title {
            lastKnownChapter = currentChapter
            ATLog(.debug, "🔄 Chapter changed - updating lock screen")
          }
        }

        statePublisher.send(.positionUpdated(position))
        updateNowPlayingInfo(position)
      }
  }

  private func setupChapterMonitorTimer() {
    chapterMonitorTimer?.cancel()
    chapterMonitorTimer = nil

    chapterMonitorTimer = Timer.publish(every: 1.0, on: .main, in: .common) // Check every second
      .autoconnect()
      .receive(on: DispatchQueue.global(qos: .userInitiated))
      .compactMap { [weak self] _ -> TrackPosition? in
        guard let self = self,
              audiobook.player.isPlaying,
              let position = audiobook.player.currentTrackPosition
        else {
          return nil
        }
        return position
      }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] position in
        guard let self = self else {
          return
        }
        checkForChapterChange(at: position)
      }
  }

  private func checkForChapterChange(at position: TrackPosition) {
    let hasChanged = hasChapterChanged(from: lastKnownChapter, to: position)
    if hasChanged {
      ATLog(.debug, "🔄 [AudiobookManager] Chapter boundary crossed - immediate lock screen update")
      updateNowPlayingInfo(position)
      lastKnownChapter = try? tableOfContents.chapter(forPosition: position)
    }
  }

  private func hasChapterChanged(from lastChapter: Chapter?, to position: TrackPosition) -> Bool {
    guard let currentChapter = try? tableOfContents.chapter(forPosition: position) else {
      return false
    }

    guard let lastChapter = lastChapter else {
      return true
    }

    return lastChapter.title != currentChapter.title ||
      lastChapter.position.track.key != currentChapter.position.track.key
  }

  public func updateNowPlayingInfo(_ position: TrackPosition?) {
    guard let currentTrackPosition = position else {
      ATLog(.debug, "🔒 [AudiobookManager] updateNowPlayingInfo called with nil position")
      return
    }

    ATLog(.info, "🔒 [AudiobookManager] updateNowPlayingInfo START - track timestamp: \(currentTrackPosition.timestamp)")

    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()

    let chapter = try? tableOfContents.chapter(forPosition: currentTrackPosition)
    let chapterTitle = chapter?.title ?? currentTrackPosition.track.title
    
    // Get chapter duration - ensure it's valid and positive
    let rawDuration = chapter?.duration ?? currentTrackPosition.track.duration
    let chapterDuration = max(1.0, abs(rawDuration)) // Ensure positive, at least 1 second
    
    ATLog(.info, "🔒 [AudiobookManager] Chapter: '\(chapterTitle ?? "nil")', rawDuration: \(rawDuration), safeDuration: \(chapterDuration)")
    
    // Get chapter-relative elapsed time (already clamped in chapterOffset)
    var chapterElapsed: Double
    if let offset = try? tableOfContents.chapterOffset(for: currentTrackPosition) {
      chapterElapsed = offset
      ATLog(.info, "🔒 [AudiobookManager] Got chapterOffset: \(offset)")
    } else {
      // Fallback: use track timestamp, but clamp it
      chapterElapsed = max(0, min(currentTrackPosition.timestamp, chapterDuration))
      ATLog(.warn, "🔒 [AudiobookManager] chapterOffset failed, using clamped timestamp: \(chapterElapsed)")
    }
    
    // FINAL SAFETY: Ensure elapsed is NEVER greater than duration
    // This is the last line of defense against negative time remaining
    if chapterElapsed > chapterDuration {
      ATLog(.error, "🔒 [AudiobookManager] CORRECTING: elapsed (\(chapterElapsed)) > duration (\(chapterDuration))")
      chapterElapsed = chapterDuration
    }
    if chapterElapsed < 0 {
      ATLog(.error, "🔒 [AudiobookManager] CORRECTING: elapsed (\(chapterElapsed)) < 0")
      chapterElapsed = 0
    }
    
    let timeRemaining = chapterDuration - chapterElapsed
    ATLog(.info, "🔒 [AudiobookManager] FINAL VALUES - elapsed: \(chapterElapsed)s, duration: \(chapterDuration)s, remaining: \(timeRemaining)s")

    nowPlayingInfo[MPMediaItemPropertyTitle] = chapterTitle
    nowPlayingInfo[MPMediaItemPropertyArtist] = metadata.title
    nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata.authors?.joined(separator: ", ")
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = chapterElapsed
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = chapterDuration
    
    // Set media type for CarPlay compatibility
    nowPlayingInfo[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue

    let playbackRate = PlaybackRate.convert(rate: audiobook.player.playbackRate)
    let isPlaying = audiobook.player.isPlaying
    nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
    // Always use 1.0 as the rate when playing (CarPlay expects this)
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
    
    ATLog(.info, "🔒 [AudiobookManager] Setting nowPlayingInfo - isPlaying: \(isPlaying), rate: \(playbackRate)")

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    
    // CRITICAL: Also set the playback state explicitly for CarPlay
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    
    ATLog(.info, "🔒 [AudiobookManager] updateNowPlayingInfo COMPLETE - playbackState: \(isPlaying ? "playing" : "paused")")
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
    var result: Result<Void, Error>?

    bookmarkDelegate?.saveListeningPosition(at: location) { serverId in
      if let _ = serverId {
        result = .success(())
      } else {
        result = .failure(NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Failed to post current location."]
        ))
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
    bookmarkDelegate?
      .fetchBookmarks(
        for: audiobook.tableOfContents.tracks,
        toc: audiobook.tableOfContents.toc
      ) { [weak self] bookmarks in
        self?.bookmarks = bookmarks.sorted {
          let formatter = ISO8601DateFormatter()
          guard let date1 = formatter.date(from: $0.lastSavedTimeStamp),
                let date2 = formatter.date(from: $1.lastSavedTimeStamp)
          else {
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
        guard let self = self else {
          return
        }

        switch playbackState {
        case let .started(trackPosition):
          handlePlaybackBegan(trackPosition)

        case let .stopped(trackPosition):
          handlePlaybackStopped(trackPosition)

        case let .failed(trackPosition, error):
          handlePlaybackFailed(trackPosition, error: error)

        case let .completed(chapter):
          handlePlaybackCompleted(chapter)

        case .unloaded:
          handlePlayerUnloaded()

        case .bookCompleted:
          playbackCompletionHandler?()
        }
      }
      .store(in: &cancellables)
  }

  private func handlePlaybackBegan(_ trackPosition: TrackPosition) {
    waitingForPlayer = false
    statePublisher.send(.playbackBegan(trackPosition))
    playbackTrackerDelegate?.playbackStarted()

    updateNowPlayingInfo(trackPosition)
    lastKnownChapter = try? tableOfContents.chapter(forPosition: trackPosition)
  }

  private func handlePlaybackStopped(_ trackPosition: TrackPosition) {
    waitingForPlayer = false
    statePublisher.send(.playbackStopped(trackPosition))
    playbackTrackerDelegate?.playbackStopped()
    
    // Save position when playback stops
    saveLocation(trackPosition)
    ATLog(.debug, "🔒 Saved position on playback stopped: \(trackPosition.timestamp)")
  }

  private func handlePlaybackFailed(_ trackPosition: TrackPosition?, error _: Error?) {
    statePublisher.send(.playbackFailed(trackPosition))
    playbackTrackerDelegate?.playbackStopped()
  }

  private func handlePlaybackCompleted(_ chapter: Chapter) {
    waitingForPlayer = false
    statePublisher.send(.playbackCompleted(chapter.position))
    
    // Save tracked time when chapter/track completes
    // This is critical for continuous playback - without this call,
    // accumulated time is lost at each track boundary
    playbackTrackerDelegate?.playbackStopped()
    
    // Save position when chapter/track completes
    saveLocation(chapter.position)
    ATLog(.debug, "🔒 Saved position on playback completed: \(chapter.position.timestamp)")
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
        guard let self = self else {
          return
        }
        switch command {
        case .play:
          // Execute play immediately - save position asynchronously
          audiobook.player.play()
          if let currentPosition = audiobook.player.currentTrackPosition {
            Task.detached(priority: .utility) { [weak self] in
              self?.saveLocation(currentPosition)
              ATLog(.debug, "🔒 Saved position after remote play: \(currentPosition.timestamp)")
            }
          }
        case .pause:
          // Execute pause immediately - save position asynchronously
          let currentPosition = audiobook.player.currentTrackPosition
          audiobook.player.pause()
          if let currentPosition = currentPosition {
            Task.detached(priority: .utility) { [weak self] in
              self?.saveLocation(currentPosition)
              ATLog(.debug, "🔒 Saved position after remote pause: \(currentPosition.timestamp)")
            }
          }
        case .playPause:
          let wasPlaying = audiobook.player.isPlaying
          let currentPosition = audiobook.player.currentTrackPosition
          // Execute toggle immediately
          if wasPlaying {
            audiobook.player.pause()
          } else {
            audiobook.player.play()
          }
          // Save position asynchronously
          if let currentPosition = currentPosition {
            Task.detached(priority: .utility) { [weak self] in
              self?.saveLocation(currentPosition)
              ATLog(.debug, "🔒 Saved position after remote playPause: \(currentPosition.timestamp)")
            }
          }
        case .skipForward:
          // Skip executes async internally, update UI immediately on completion
          audiobook.player.skipPlayhead(DefaultAudiobookManager.skipTimeInterval) { [weak self] newPosition in
            guard let self = self, let newPosition = newPosition else { return }
            // Update UI on main thread immediately
            DispatchQueue.main.async {
              self.updateNowPlayingInfo(newPosition)
            }
            // Save position asynchronously on background
            Task.detached(priority: .utility) {
              self.saveLocation(newPosition)
              ATLog(.debug, "🔒 Saved position after remote skip forward: \(newPosition.timestamp)")
            }
          }
        case .skipBackward:
          // Skip executes async internally, update UI immediately on completion
          audiobook.player.skipPlayhead(-DefaultAudiobookManager.skipTimeInterval) { [weak self] newPosition in
            guard let self = self, let newPosition = newPosition else { return }
            // Update UI on main thread immediately
            DispatchQueue.main.async {
              self.updateNowPlayingInfo(newPosition)
            }
            // Save position asynchronously on background
            Task.detached(priority: .utility) {
              self.saveLocation(newPosition)
              ATLog(.debug, "🔒 Saved position after remote skip backward: \(newPosition.timestamp)")
            }
          }
        case let .changePlaybackRate(rate):
          if let playbackRate = PlaybackRate(rawValue: Int(rate * 100)) {
            audiobook.player.playbackRate = playbackRate
          }
        }
      }
      .store(in: &cancellables)
  }

  deinit {
    ATLog(.debug, "DefaultAudiobookManager is deinitializing.")
    timer?.cancel()
    timer = nil
    chapterMonitorTimer?.cancel()
    chapterMonitorTimer = nil
    cancellables.removeAll()
  }
}
