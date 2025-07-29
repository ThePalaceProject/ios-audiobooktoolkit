//
//  LCPStreamingPlayer.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import AVFoundation
import ReadiumShared

#if LCP

/// LCP Streaming Player for encrypted audiobook playback
/// This player integrates AVPlayer with LCPResourceLoaderDelegate to provide
/// seamless streaming of encrypted LCP audiobooks with real-time decryption
public class LCPStreamingPlayer: Player {
  
  // MARK: - Player Protocol Properties
  
  public var isPlaying: Bool {
    return avQueuePlayer.rate > 0
  }
  
  public var playbackRate: PlaybackRate {
    didSet {
      avQueuePlayer.rate = Float(playbackRate.rawValue)
    }
  }
  
  public var tableOfContents: [ChapterLocation] = []
  
  public var currentChapterLocation: ChapterLocation? {
    guard let currentItem = avQueuePlayer.currentItem,
          let index = playerItems.firstIndex(of: currentItem),
          index < tableOfContents.count else {
      return nil
    }
    return tableOfContents[index]
  }
  
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
  
  // MARK: - Initialization
  
  /// Initialize LCP Streaming Player
  /// - Parameters:
  ///   - tableOfContents: Chapter information for the audiobook
  ///   - decryptor: LCP streaming provider for decryption
  ///   - publication: Readium Publication with track information
  ///   - rangeRetriever: HTTP range retriever for byte-range requests
  public init(
    tableOfContents: [ChapterLocation],
    decryptor: LCPStreamingProvider,
    publication: Publication,
    rangeRetriever: HTTPRangeRetriever
  ) {
    self.tableOfContents = tableOfContents
    self.publication = publication
    self.decryptor = decryptor
    self.rangeRetriever = rangeRetriever
    self.playbackRate = .normalTime
    self.backgroundQueue = DispatchQueue(label: "lcp-streaming-player", qos: .userInitiated)
    
    // Initialize AVQueuePlayer
    self.avQueuePlayer = AVQueuePlayer()
    
    // Create resource loader delegate for LCP decryption
    self.resourceLoaderDelegate = LCPResourceLoaderDelegate(
      publication: publication,
      decryptor: decryptor,
      rangeRetriever: rangeRetriever
    )
    
    // Setup player items for all tracks in the publication
    setupPlayerItems()
    
    // Setup playback observers
    setupObservers()
    
    ATLog(.debug, "LCPStreamingPlayer initialized with \(tableOfContents.count) chapters")
  }
  
  deinit {
    removeObservers()
    ATLog(.debug, "LCPStreamingPlayer deinitialized")
  }
  
  // MARK: - Player Protocol Methods
  
  public func play() {
    ATLog(.debug, "Starting LCP streaming playback")
    avQueuePlayer.play()
  }
  
  public func pause() {
    ATLog(.debug, "Pausing LCP streaming playback")
    avQueuePlayer.pause()
  }
  
  public func skipPlayhead(_ timeInterval: TimeInterval) {
    guard let currentItem = avQueuePlayer.currentItem else { return }
    
    let currentTime = currentItem.currentTime()
    let targetTime = CMTimeAdd(currentTime, CMTime(seconds: timeInterval, preferredTimescale: 1000))
    
    // Ensure we don't seek beyond the item duration
    let duration = currentItem.duration
    let clampedTime = CMTimeMinimum(targetTime, duration)
    let positiveTime = CMTimeMaximum(clampedTime, .zero)
    
    ATLog(.debug, "Seeking LCP stream by \(timeInterval) seconds")
    avQueuePlayer.seek(to: positiveTime, toleranceBefore: .zero, toleranceAfter: .zero)
  }
  
  public func playAtLocation(_ location: ChapterLocation) {
    ATLog(.debug, "Seeking to chapter: \(location.title ?? "Unknown")")
    
    // Find the player item for this chapter
    guard let chapterIndex = tableOfContents.firstIndex(where: { $0.equals(location) }),
          chapterIndex < playerItems.count else {
      ATLog(.error, "Chapter not found in table of contents")
      return
    }
    
    // Clear current queue and rebuild from the target chapter
    rebuildQueueFromChapter(startingAt: chapterIndex)
    
    // Seek to the specific time offset within the chapter if provided
    if let offset = location.offset {
      let targetTime = CMTime(seconds: offset, preferredTimescale: 1000)
      avQueuePlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
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
  
  // MARK: - Private Methods
  
  /// Setup AVPlayer items for all tracks using custom URL scheme
  private func setupPlayerItems() {
    ATLog(.debug, "Setting up player items for \(publication.readingOrder.count) tracks")
    
    for (index, readingOrderItem) in publication.readingOrder.enumerated() {
      // Create custom URL for LCP resource loader
      let customURL = createCustomStreamingURL(for: readingOrderItem, trackIndex: index)
      
      // Create AVURLAsset with custom URL
      let asset = AVURLAsset(url: customURL)
      
      // Set the resource loader delegate for LCP decryption
      asset.resourceLoader.setDelegate(
        resourceLoaderDelegate,
        queue: backgroundQueue
      )
      
      // Create player item
      let playerItem = AVPlayerItem(asset: asset)
      playerItems.append(playerItem)
      
      ATLog(.debug, "Created player item for track: \(readingOrderItem.href.path)")
    }
    
    // Add initial items to the queue
    rebuildQueueFromChapter(startingAt: 0)
  }
  
  /// Create custom streaming URL for resource loader
  private func createCustomStreamingURL(for item: Link, trackIndex: Int) -> URL {
    // Create a custom URL scheme that the resource loader can intercept
    // Format: lcp-stream://trackkey/path/to/audio.mp3
    let trackKey = "track\(trackIndex)"
    let originalPath = item.href.path
    
    // Encode the original path to handle special characters
    let encodedPath = originalPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? originalPath
    
    let customURLString = "lcp-stream://\(trackKey)/\(encodedPath)"
    
    guard let customURL = URL(string: customURLString) else {
      ATLog(.error, "Failed to create custom URL for track: \(originalPath)")
      // Fallback to a simple URL
      return URL(string: "lcp-stream://fallback/\(trackIndex).mp3")!
    }
    
    ATLog(.debug, "Created custom streaming URL: \(customURL)")
    return customURL
  }
  
  /// Rebuild the AVQueuePlayer queue starting from a specific chapter
  private func rebuildQueueFromChapter(startingAt chapterIndex: Int) {
    // Remove all items from the current queue
    avQueuePlayer.removeAllItems()
    
    // Add items starting from the specified chapter
    for index in chapterIndex..<playerItems.count {
      avQueuePlayer.insert(playerItems[index], after: nil)
    }
    
    ATLog(.debug, "Rebuilt queue starting from chapter \(chapterIndex)")
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
    
    ATLog(.debug, "Setup playback observers")
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
    
    ATLog(.debug, "Removed playback observers")
  }
  
  /// Handle periodic time updates
  private func handleTimeUpdate(_ time: CMTime) {
    // Update any progress tracking here
    // This is where you would notify delegates about playback progress
    let currentTimeSeconds = CMTimeGetSeconds(time)
    
    if currentTimeSeconds.isFinite && currentTimeSeconds >= 0 {
      // You can add progress tracking logic here
      ATLog(.debug, "LCP playback progress: \(currentTimeSeconds) seconds")
    }
  }
  
  /// Handle when an item finishes playing
  private func handleItemDidPlayToEnd(_ notification: Notification) {
    guard let playerItem = notification.object as? AVPlayerItem,
          playerItem == avQueuePlayer.currentItem else {
      return
    }
    
    ATLog(.debug, "LCP track finished playing, advancing to next")
    
    // AVQueuePlayer should automatically advance to the next item
    // But we can add custom logic here if needed
  }
}

// MARK: - Helper Extensions

private extension ChapterLocation {
  /// Check if two chapter locations are equal
  func equals(_ other: ChapterLocation) -> Bool {
    // Compare based on your ChapterLocation implementation
    // This is a simplified comparison - adjust based on your actual implementation
    return self.title == other.title && 
           self.playheadOffset == other.playheadOffset
  }
}

#endif 

