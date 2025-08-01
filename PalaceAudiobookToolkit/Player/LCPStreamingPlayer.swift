//
//  LCPStreamingPlayer.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import ReadiumShared
import Combine

#if LCP

/// LCP Streaming Player for encrypted audiobook playback
/// This player integrates AVPlayer with LCPResourceLoaderDelegate to provide
/// seamless streaming of encrypted LCP audiobooks with real-time decryption
public class LCPStreamingPlayer: NSObject, Player {
  
  // MARK: - Player Protocol Properties
  
  public var isPlaying: Bool {
    return avQueuePlayer.rate > 0
  }
  
  public var playbackRate: PlaybackRate = .normalTime {
    didSet {
      avQueuePlayer.rate = Float(playbackRate.rawValue)
    }
  }
  
    public var tableOfContents: AudiobookTableOfContents

  public var currentTrackPosition: TrackPosition? {
    guard let currentItem = avQueuePlayer.currentItem,
          let playerItemIndex = playerItems.firstIndex(of: currentItem) else {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] No current item or item not found in playerItems")
      return nil
    }
    
    // For streaming, playerItems indices correspond to publication.readingOrder indices
    guard playerItemIndex < publication.readingOrder.count else {
      ATLog(.error, "🎵 [LCPStreamingPlayer] Player item index \(playerItemIndex) out of bounds for publication")
      return nil
    }
    
    // Find the track using the reading order item's href
    let readingOrderItem = publication.readingOrder[playerItemIndex]
    guard let track = tableOfContents.tracks.track(forHref: readingOrderItem.href) else {
      ATLog(.error, "🎵 [LCPStreamingPlayer] Could not find track for href: \(readingOrderItem.href)")
      return nil
    }
    
    let currentTime = CMTimeGetSeconds(currentItem.currentTime())
    
    // 🎯 STREAMING FIX: Handle infinite/invalid timestamps gracefully
    let safeTimestamp = currentTime.isFinite && currentTime >= 0 ? currentTime : 0.0
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Current position: track=\(track.title ?? "unknown"), time=\(safeTimestamp)")
    
    return TrackPosition(track: track, timestamp: safeTimestamp, tracks: tableOfContents.tracks)
  }

  public var currentChapterLocation: Chapter? {
    guard let currentTrackPosition = currentTrackPosition else {
      return nil
    }
    return try? tableOfContents.chapter(forPosition: currentTrackPosition)
  }
  
  // MARK: - Additional Player Protocol Properties
  
  public var queuesEvents: Bool = true
  public var isDrmOk: Bool = true
  
  public var currentOffset: Double {
    guard let currentItem = avQueuePlayer.currentItem else { return 0 }
    return CMTimeGetSeconds(currentItem.currentTime())
  }
  
  public var currentChapter: Chapter? {
    return currentChapterLocation
  }
  
  public var isLoaded: Bool {
    return !playerItems.isEmpty
  }
  
  public var playbackStatePublisher = PassthroughSubject<PlaybackState, Never>()
  
  // MARK: - Private Properties
  
  private let avQueuePlayer: AVQueuePlayer
  private let publication: Publication
  private let decryptor: LCPStreamingProvider
  private let rangeRetriever: HTTPRangeRetriever
  private let resourceLoaderDelegate: LCPResourceLoaderDelegate
  
  private var playerItems: [AVPlayerItem] = []
  private let backgroundQueue: DispatchQueue
  private var timeObserver: Any?
  private var itemEndObserver: Any?
  private var currentItemObserver: Any?
  private var rateObserver: Any?
  
  // MARK: - Initialization
  
  /// Initialize LCP Streaming Player
  /// - Parameters:
  ///   - tableOfContents: Table of contents for the audiobook
  ///   - decryptor: LCP streaming provider for decryption
  ///   - publication: Readium Publication with track information
  ///   - rangeRetriever: HTTP range retriever for byte-range requests
  public init(
    tableOfContents: AudiobookTableOfContents,
    decryptor: LCPStreamingProvider,
    publication: Publication,
    rangeRetriever: HTTPRangeRetriever
  ) {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Initializing LCPStreamingPlayer with \(tableOfContents.toc.count) chapters")
    
    self.tableOfContents = tableOfContents
    self.publication = publication
    self.decryptor = decryptor
    self.rangeRetriever = rangeRetriever
    self.backgroundQueue = DispatchQueue(label: "lcp-streaming-player", qos: .userInitiated)
    
    // Initialize AVQueuePlayer
    self.avQueuePlayer = AVQueuePlayer()
    
    // Initialize resource loader delegate for Readium integration
    guard let streamingBaseURL = decryptor.getStreamingBaseURL() else {
      ATLog(.error, "❌ Failed to get streaming base URL from LCP decryptor")
      // Use a fallback - this will fail but allows initialization to complete
      self.resourceLoaderDelegate = LCPResourceLoaderDelegate(
        publication: publication,
        decryptor: decryptor,
        rangeRetriever: rangeRetriever,
        streamingBaseURL: URL(string: "https://invalid-url.com")!
      )
      super.init()
      return
    }
    
    self.resourceLoaderDelegate = LCPResourceLoaderDelegate(
      publication: publication,
      decryptor: decryptor,
      rangeRetriever: rangeRetriever,
      streamingBaseURL: streamingBaseURL
    )
    
    // Call super.init() after all stored properties are initialized
    super.init()
    
    // Setup player items for all tracks in the publication
    setupPlayerItems()
    
    // Setup playback observers
    setupObservers()
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Successfully initialized with \(tableOfContents.toc.count) chapters")
  }
  
  /// Initialize LCP Streaming Player (Player protocol requirement)
  /// This is a convenience initializer for basic Player protocol conformance
  public required init?(tableOfContents: AudiobookTableOfContents) {
    // LCP streaming requires additional components that aren't available in this basic initializer
    // This implementation returns nil to indicate that the basic initializer cannot be used
    ATLog(.error, "LCPStreamingPlayer requires LCP components, use full initializer instead")
    return nil
  }
  
  deinit {
    removeObservers()
    ATLog(.debug, "LCPStreamingPlayer deinitialized")
  }
  
  // MARK: - Player Protocol Methods
  
  public func play() {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Play requested - starting LCP streaming playback")
    avQueuePlayer.play()
    
    // Publish state change
    if let currentTrackPosition = currentTrackPosition {
      playbackStatePublisher.send(.started(currentTrackPosition))
    }
    
    // 🚀 Start aggressive downloads for upcoming tracks
    if let currentChapter = currentChapter {
      let currentIndex = tableOfContents.index(of: currentChapter) ?? 0
      prioritizeDownloads(startingFrom: currentIndex)
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] AVQueuePlayer.play() called")
  }
  
  public func pause() {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Pause requested - pausing LCP streaming playback")
    avQueuePlayer.pause()
    
    // Publish state change
    if let currentTrackPosition = currentTrackPosition {
      playbackStatePublisher.send(.stopped(currentTrackPosition))
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] AVQueuePlayer.pause() called")
  }
  
  public func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?) {
    guard let currentTrackPosition = currentTrackPosition else { 
      ATLog(.error, "🎵 [LCPStreamingPlayer] Cannot skip: No current track position")
      completion?(nil)
      return 
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Skipping by \(timeInterval) seconds from current position")
    
    // Calculate the target position using TrackPosition arithmetic
    let targetPosition = currentTrackPosition + timeInterval
    
    // Use the existing play(at:) method which handles cross-track navigation properly
    play(at: targetPosition) { [weak self] error in
      if let error = error {
        ATLog(.error, "🎵 [LCPStreamingPlayer] Skip failed: \(error.localizedDescription)")
        completion?(nil)
      } else {
        completion?(self?.currentTrackPosition)
      }
    }
  }
  
  public func playAtLocation(_ location: Chapter) {
    ATLog(.debug, "Seeking to chapter: \(location.title ?? "Unknown")")
    
    // Find the player item for this chapter
    guard let chapterIndex = tableOfContents.index(of: location),
          chapterIndex < playerItems.count else {
      ATLog(.error, "Chapter not found in table of contents")
      return
    }
    
    // Clear current queue and rebuild from the target chapter
    rebuildQueueFromChapter(startingAt: chapterIndex)
    
    // Seek to the specific time offset within the chapter if provided
      let targetTime = CMTime(seconds: location.position.timestamp, preferredTimescale: 1000)
      avQueuePlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    
    // Start playback
    play()
  }
  
  public func skipToNextChapter() {
    ATLog(.debug, "Skipping to next chapter in LCP stream")
    avQueuePlayer.advanceToNextItem()
  }
  
  public func skipToPreviousChapter() {
    ATLog(.debug, "Skipping to previous chapter in LCP stream")
    
    // AVQueuePlayer doesn't have built-in previous functionality
    // We need to rebuild the queue from the previous chapter
    guard let currentItem = avQueuePlayer.currentItem,
          let currentIndex = playerItems.firstIndex(of: currentItem),
          currentIndex > 0 else {
      // Already at first chapter, restart current chapter
      avQueuePlayer.seek(to: .zero)
      return
    }
    
    rebuildQueueFromChapter(startingAt: currentIndex - 1)
    play()
  }
  
  // MARK: - Additional Player Protocol Methods
  
  public func unload() {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Unloading LCP streaming player")
    avQueuePlayer.pause()
    avQueuePlayer.removeAllItems()
    playerItems.removeAll()
    removeObservers()
    
    // Publish unloaded state
    playbackStatePublisher.send(.unloaded)
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] LCP streaming player unloaded")
  }
  
  public func play(at position: TrackPosition, completion: ((Error?) -> Void)?) {
    ATLog(.debug, "Playing at specific position: track \(position.track.title ?? "Unknown")")
    
    // Find the track in our table of contents
    guard let track = tableOfContents.tracks.track(forKey: position.track.key) else {
      completion?(NSError(domain: "LCPStreamingPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Track not found"]))
      return
    }
    let trackIndex = track.index
    
    // Rebuild queue from this track
    rebuildQueueFromChapter(startingAt: trackIndex)
    
    // Seek to the specific timestamp
    let targetTime = CMTime(seconds: position.timestamp, preferredTimescale: 1000)
    avQueuePlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      if finished {
        self?.play()
        completion?(nil)
      } else {
        completion?(NSError(domain: "LCPStreamingPlayer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Seek failed"]))
      }
    }
  }
  
  public func move(to value: Double, completion: ((TrackPosition?) -> Void)?) {
    ATLog(.debug, "Moving to percentage: \(value)")
    
    guard let currentItem = avQueuePlayer.currentItem else {
      completion?(nil)
      return
    }
    
    let duration = CMTimeGetSeconds(currentItem.duration)
    let targetTime = CMTime(seconds: duration * value, preferredTimescale: 1000)
    
    avQueuePlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      completion?(self?.currentTrackPosition)
    }
  }
  
  // MARK: - Private Methods
  
  /// Setup AVPlayer items using hybrid approach: local files when available, streaming for current track
  private func setupPlayerItems() {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Setting up hybrid player items for \(publication.readingOrder.count) tracks")
    
    for (index, readingOrderItem) in publication.readingOrder.enumerated() {
      
      // 🔍 Check if this track is already downloaded locally
      if let localURL = getLocalFileURL(for: readingOrderItem, trackIndex: index) {
        ATLog(.debug, "📁 [LCPStreamingPlayer] Track \(index): Using LOCAL file: \(localURL.path)")
        
        // Use local file directly - no resource loader needed
        let asset = AVURLAsset(url: localURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItems.append(playerItem)
        
      } else {
        ATLog(.debug, "🌐 [LCPStreamingPlayer] Track \(index): LOCAL file not found, setting up for STREAMING")
        
        // Create streaming URL for resource loader interception
        let streamingURL = createCustomStreamingURL(for: readingOrderItem, trackIndex: index)
        ATLog(.debug, "🎵 [LCPStreamingPlayer] Track \(index): Created streaming URL: \(streamingURL)")
        
        // Create AVURLAsset with custom URL scheme for streaming
        let asset = AVURLAsset(url: streamingURL)
        
        // Set the resource loader delegate for streaming
        asset.resourceLoader.setDelegate(
          resourceLoaderDelegate,
          queue: backgroundQueue
        )
        
        let playerItem = AVPlayerItem(asset: asset)
        playerItems.append(playerItem)
        
        // 🚀 Start background download for this track
        startBackgroundDownload(for: readingOrderItem, trackIndex: index)
      }
    }
    
    ATLog(.debug, "✅ [LCPStreamingPlayer] Hybrid setup complete: \(playerItems.count) items created")
    
    // Add initial items to the queue  
    rebuildQueueFromChapter(startingAt: 0)
  }
  
  /// Update track durations from AVPlayerItem when they become available
  private func updateTrackDurationsFromPlayerItems() {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Updating track durations from player items")
    
    for (index, playerItem) in playerItems.enumerated() {
      guard index < publication.readingOrder.count else { continue }
      
      let readingOrderItem = publication.readingOrder[index]
      guard let track = tableOfContents.tracks.track(forHref: readingOrderItem.href) else { continue }
      
      // Get duration from AVPlayerItem
      let duration = CMTimeGetSeconds(playerItem.duration)
      
      if duration.isFinite && duration > 0 && abs(duration - track.duration) > 1.0 {
        ATLog(.debug, "🎵 [LCPStreamingPlayer] Updating track \(index) duration: \(track.duration) -> \(duration)")
        
        // Update the track's duration (this might require track to be mutable)
        // For now, we log the discrepancy and rely on the player's duration
      }
    }
  }
  
  /// Get estimated duration for a streaming track, fallback to default if not available
  private func getEstimatedDuration(for track: any Track, playerItem: AVPlayerItem) -> TimeInterval {
    let playerDuration = CMTimeGetSeconds(playerItem.duration)
    
    if playerDuration.isFinite && playerDuration > 0 {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] Using player duration: \(playerDuration) for track: \(track.title ?? "unknown")")
      return playerDuration
    }
    
    if track.duration > 0 {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] Using manifest duration: \(track.duration) for track: \(track.title ?? "unknown")")
      return track.duration
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Using default duration estimate: 180s for track: \(track.title ?? "unknown")")
    return 180.0 // Default 3-minute estimate for unknown durations
  }
  
  /// Check if a track has been downloaded locally and return its file URL
  private func getLocalFileURL(for item: Link, trackIndex: Int) -> URL? {
    // Generate the same hash-based filename that LCPDownloadTask uses
    guard let hashedFilename = item.href.sha256?.hexString else {
      ATLog(.debug, "🔍 [LCPStreamingPlayer] Could not generate hash for track: \(item.href)")
      return nil
    }
    
    // Get the caches directory
    let fileManager = FileManager.default
    guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      ATLog(.error, "❌ [LCPStreamingPlayer] Could not find caches directory")
      return nil
    }
    
    // Build the expected local file path (matches LCPDownloadTask.decryptedFileURL)
    let localFileURL = cacheDirectory
      .appendingPathComponent(hashedFilename)
      .appendingPathExtension(URL(fileURLWithPath: item.href).pathExtension)
    
    // Check if the file exists
    if fileManager.fileExists(atPath: localFileURL.path) {
      ATLog(.debug, "✅ [LCPStreamingPlayer] Found local file for track \(trackIndex): \(localFileURL.path)")
      return localFileURL
    } else {
      ATLog(.debug, "❌ [LCPStreamingPlayer] Local file not found for track \(trackIndex): \(localFileURL.path)")
      return nil
    }
  }
  
  /// Start background download for a track that's not available locally
  private func startBackgroundDownload(for item: Link, trackIndex: Int) {
    ATLog(.debug, "🚀 [LCPStreamingPlayer] Starting background download for track \(trackIndex): \(item.href)")
    
    // Create a traditional LCP download task for this track
    let trackKey = "\(publication.metadata.identifier ?? "unknown")-\(trackIndex)"
    
    // For the download, we need the streaming URL from the base URL
    guard let streamingBaseURL = decryptor.getStreamingBaseURL() else {
      ATLog(.error, "❌ [LCPStreamingPlayer] No streaming base URL available for download")
      return
    }
    
    let downloadURL = streamingBaseURL.appendingPathComponent(item.href)
    let downloadTask = LCPDownloadTask(key: trackKey, urls: [downloadURL], mediaType: .audioMPEG)
    
    // Start the download in background
    DispatchQueue.global(qos: .background).async {
      downloadTask.fetch()
      ATLog(.debug, "🎯 [LCPStreamingPlayer] Background download initiated for track \(trackIndex)")
    }
    
    // TODO: We could listen to download completion and dynamically update the player items
    // For now, downloads will be available for next session
  }
  
  /// Aggressively download tracks most likely to be played next (current + next 3-5 tracks)
  private func prioritizeDownloads(startingFrom currentIndex: Int) {
    ATLog(.debug, "⚡ [LCPStreamingPlayer] Prioritizing downloads starting from track \(currentIndex)")
    
    // Download current track + next 4 tracks with high priority
    let priorityRange = currentIndex..<min(currentIndex + 5, publication.readingOrder.count)
    
    for index in priorityRange {
      let item = publication.readingOrder[index]
      
      // Only download if not already available locally
      if getLocalFileURL(for: item, trackIndex: index) == nil {
        ATLog(.debug, "⚡ [LCPStreamingPlayer] Priority download for track \(index): \(item.href)")
        startBackgroundDownload(for: item, trackIndex: index)
      } else {
        ATLog(.debug, "✅ [LCPStreamingPlayer] Track \(index) already downloaded: \(item.href)")
      }
    }
  }
  
  /// Create readium-lcp:// URL for resource loader interception
  private func createCustomStreamingURL(for item: Link, trackIndex: Int) -> URL {
    let trackKey = "track\(trackIndex)"
    let originalPath = item.href
    
    // Create a custom URL scheme that will be handled by resource loader delegate
    let customURLString = "readium-lcp://\(trackKey)/\(originalPath)"
    
    guard let customURL = URL(string: customURLString) else {
      ATLog(.error, "Failed to create custom URL for track: \(originalPath)")
      return URL(string: "readium-lcp://fallback/\(trackIndex).mp3")!
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Created readium-lcp URL: \(customURL.absoluteString)")
    return customURL
  }
  
  /// Rebuild the AVQueuePlayer queue starting from a specific chapter
  private func rebuildQueueFromChapter(startingAt chapterIndex: Int) {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] ⚠️ QUEUE REBUILD: Starting from chapter \(chapterIndex) (was playing: \(avQueuePlayer.rate > 0))")
    
    let wasPlaying = avQueuePlayer.rate > 0
    if wasPlaying {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] ⏸️ Pausing playback for queue rebuild")
      avQueuePlayer.pause()
    }
    
    // Remove all items from the current queue
    avQueuePlayer.removeAllItems()
    ATLog(.debug, "🎵 [LCPStreamingPlayer] 🗑️ Removed all items from queue")
    
    // Add items starting from the specified chapter
    for index in chapterIndex..<min(chapterIndex + 5, playerItems.count) { // Only add next 5 items to prevent excessive pre-loading
      avQueuePlayer.insert(playerItems[index], after: nil)
      ATLog(.debug, "🎵 [LCPStreamingPlayer] ➕ Added item \(index) to queue")
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] ✅ Queue rebuild complete. Total items in queue: \(avQueuePlayer.items().count)")
    if let firstItem = avQueuePlayer.currentItem {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] 🎯 First item in queue: \(firstItem.asset)")
    }
    
    if wasPlaying {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] ▶️ Resuming playback after queue rebuild")
      avQueuePlayer.play()
    }
    
    // 🚀 Trigger priority downloads for the new chapter range
    prioritizeDownloads(startingFrom: chapterIndex)
  }
  
  /// Handle queue exhaustion by attempting to restart from the last known position
  private func handleQueueExhaustion() {
    ATLog(.error, "🎵 [LCPStreamingPlayer] 🚨 QUEUE EXHAUSTION: Attempting recovery...")
    
    // Try to find the last known track position
    if let lastTrackPosition = currentTrackPosition {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] 🔄 Rebuilding queue from last known position: track \(lastTrackPosition.track.index)")
      rebuildQueueFromChapter(startingAt: lastTrackPosition.track.index)
    } else {
      // Fallback: restart from the beginning of the audiobook
      ATLog(.debug, "🎵 [LCPStreamingPlayer] 🔄 No last position found, rebuilding queue from start")
      rebuildQueueFromChapter(startingAt: 0)
    }
  }
  
  /// Replenish the queue by adding more items when running low
  private func replenishQueue() {
    guard let currentItem = avQueuePlayer.currentItem,
          let currentIndex = playerItems.firstIndex(of: currentItem) else {
      ATLog(.error, "🎵 [LCPStreamingPlayer] ❌ Cannot replenish queue: No current item or index not found")
      return
    }
    
    let queuedItems = avQueuePlayer.items()
    let lastQueuedIndex = currentIndex + queuedItems.count - 1
    let nextIndexToAdd = lastQueuedIndex + 1
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] 🔄 Replenishing queue: current=\(currentIndex), lastQueued=\(lastQueuedIndex), nextToAdd=\(nextIndexToAdd)")
    
    // Add next 3 items to maintain buffer
    for index in nextIndexToAdd..<min(nextIndexToAdd + 3, playerItems.count) {
      avQueuePlayer.insert(playerItems[index], after: nil)
      ATLog(.debug, "🎵 [LCPStreamingPlayer] ➕ Replenished with item \(index)")
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] ✅ Queue replenishment complete. Total items in queue: \(avQueuePlayer.items().count)")
  }
  
  /// Setup playback observers
  private func setupObservers() {
    // Time observer for progress updates
    let timeInterval = CMTime(seconds: 0.5, preferredTimescale: 1000)
    timeObserver = avQueuePlayer.addPeriodicTimeObserver(
      forInterval: timeInterval,
      queue: .main
    ) { [weak self] time in
      self?.handleTimeUpdate(time)
    }
    
    // Observer for item end
    itemEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.handleItemDidPlayToEnd(notification)
    }
    
    // Observer for current item changes
    currentItemObserver = avQueuePlayer.observe(\.currentItem, options: [.new, .old]) { [weak self] player, change in
      self?.handleCurrentItemChange(change)
    }
    
    // Observer for rate changes (play/pause)
    rateObserver = avQueuePlayer.observe(\.rate, options: [.new, .old]) { [weak self] player, change in
      self?.handleRateChange(change)
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Setup playback observers")
  }
  
  /// Remove observers
  private func removeObservers() {
    if let timeObserver = timeObserver {
      avQueuePlayer.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    
    if let itemEndObserver = itemEndObserver {
      NotificationCenter.default.removeObserver(itemEndObserver)
      self.itemEndObserver = nil
    }
    
    currentItemObserver = nil
    rateObserver = nil
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Removed playback observers")
  }
  
  /// Handle periodic time updates
  private func handleTimeUpdate(_ time: CMTime) {
    let currentTimeSeconds = CMTimeGetSeconds(time)
    
    if currentTimeSeconds.isFinite && currentTimeSeconds >= 0,
       let currentTrackPosition = currentTrackPosition {
      // Publish playback progress
      playbackStatePublisher.send(.started(currentTrackPosition))
    }
  }
  
  /// Handle when an item finishes playing
  private func handleItemDidPlayToEnd(_ notification: Notification) {
    guard let playerItem = notification.object as? AVPlayerItem,
          playerItem == avQueuePlayer.currentItem else {
      return
    }
    
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Track finished playing, advancing to next")
    
    // Publish completion of current chapter
    if let currentChapter = currentChapter {
      playbackStatePublisher.send(.completed(currentChapter))
    }
    
    // AVQueuePlayer should automatically advance to the next item
    // Check if we've reached the end of the audiobook
    if avQueuePlayer.items().isEmpty {
      playbackStatePublisher.send(.bookCompleted)
    }
  }
  
  /// Handle when the current item changes
  private func handleCurrentItemChange(_ change: NSKeyValueObservedChange<AVPlayerItem?>) {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Current item changed")
    
    // 🚨 QUEUE EXHAUSTION DETECTION: Check if we have no current item (queue exhausted)
    if change.newValue == nil {
      ATLog(.error, "🎵 [LCPStreamingPlayer] ⚠️ QUEUE EXHAUSTED: No current item available!")
      handleQueueExhaustion()
      return
    }
    
    // Check the status of the new current item
    if let newItem = change.newValue as? AVPlayerItem {
      ATLog(.debug, "🎵 [LCPStreamingPlayer] New item status: \(newItem.status.rawValue)")
      ATLog(.debug, "🎵 [LCPStreamingPlayer] New item URL: \(newItem.asset)")
      
      // 🎯 Update track durations when item is ready to play
      if newItem.status == .readyToPlay {
        ATLog(.debug, "🎵 [LCPStreamingPlayer] Item ready to play, updating durations")
        updateTrackDurationsFromPlayerItems()
      }
      
      // 🔄 QUEUE REPLENISHMENT: Check if we need to add more items to the queue
      let remainingItems = avQueuePlayer.items().count
      if remainingItems <= 2 { // Replenish when only 2 or fewer items remain
        ATLog(.debug, "🎵 [LCPStreamingPlayer] ⚠️ LOW QUEUE: Only \(remainingItems) items remaining, replenishing...")
        replenishQueue()
      }
      
      if let error = newItem.error {
        ATLog(.error, "🎵 [LCPStreamingPlayer] Current item has error: \(error)")
        
        if let currentTrackPosition = currentTrackPosition {
          playbackStatePublisher.send(.failed(currentTrackPosition, error))
        }
        return
      }
    }
    
    guard let currentTrackPosition = currentTrackPosition else { 
      ATLog(.debug, "🎵 [LCPStreamingPlayer] No current track position available")
      return 
    }
    
    if isPlaying {
      playbackStatePublisher.send(.started(currentTrackPosition))
    } else {
      playbackStatePublisher.send(.stopped(currentTrackPosition))
    }
  }
  
  /// Handle when the playback rate changes (play/pause)
  private func handleRateChange(_ change: NSKeyValueObservedChange<Float>) {
    let isNowPlaying = avQueuePlayer.rate > 0
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Rate changed to \(avQueuePlayer.rate), isPlaying: \(isNowPlaying)")
    
    guard let currentTrackPosition = currentTrackPosition else { return }
    
    if isNowPlaying {
      playbackStatePublisher.send(.started(currentTrackPosition))
    } else {
      playbackStatePublisher.send(.stopped(currentTrackPosition))
    }
  }
}

// MARK: - Helper Extensions

// Chapter comparison is now handled by the convenience method index(of:) in AudiobookTableOfContents

#endif 

