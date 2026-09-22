//
//  LCPStreamingPlayer.swift
//  PalaceAudiobookToolkit
//
//  LCP streaming player using custom URLs and resource loader.
//

import AVFoundation
import Foundation
import ObjectiveC
import ReadiumShared

/// LCP streaming player that uses custom lcp:// URLs with resource loader
class LCPStreamingPlayer: OpenAccessPlayer, StreamingCapablePlayer {
  // MARK: - StreamingCapablePlayer conformance

  public func setStreamingProvider(_ provider: StreamingResourceProvider) {
    streamingProvider = provider
    sharedResourceLoader = LCPResourceLoaderDelegate(provider: provider)
  }

  private weak var streamingProvider: StreamingResourceProvider?
  private let resourceLoaderQueue = DispatchQueue(label: "com.palace.lcp-streaming-loader", qos: .userInitiated)
  /// Replaces a `private static var … : UInt8 = 0` passed as `&Self…`, which
  /// strict concurrency checking diagnoses as global mutable state.
  private static let resourceLoaderAssocKey = AssociatedObjectKey()
  private let decryptionDelegate: DRMDecryptor?

  public var decryptor: DRMDecryptor? {
    decryptionDelegate
  }

  private var forceStreamingTrackKeys = Set<String>()
  private let compositionQueue = DispatchQueue(label: "com.palace.lcp.local-composition", qos: .userInitiated)

  private var sharedResourceLoader: LCPResourceLoaderDelegate?
  private var isObservingTimeControlStatus = false
  private var suppressAudibleUntilPlaying = false
  private var lastStartedItemKey: String?
  // Internal (not private) so the test target's @testable import can read
  // it from the contract tests — verifies that seekTo's same-track
  // fast-path flag is still set/cleared post-async-migration.
  internal var isSeekingWithinSameTrack = false
  private var loadTimeoutWorkItem: DispatchWorkItem?

  override var currentOffset: Double {
    guard let currentTrackPosition, let currentChapter else {
      return 0
    }

    let offset = (try? currentTrackPosition - currentChapter.position) ?? 0.0
    return offset
  }

  init(tableOfContents: AudiobookTableOfContents, drmDecryptor: DRMDecryptor? = nil) {
    decryptionDelegate = drmDecryptor
    super.init(tableOfContents: tableOfContents)
  }

  required init(tableOfContents _: AudiobookTableOfContents) {
    fatalError("init(tableOfContents:) has not been implemented")
  }

  override func configurePlayer() {
    setupAudioSession()
    addPlayerObservers()

    avQueuePlayer.actionAtItemEnd = .none
    avQueuePlayer.automaticallyWaitsToMinimizeStalling = true
    avQueuePlayer.isMuted = false
    isLoaded = false
  }

  override func addPlayerObservers() {
    super.addPlayerObservers()
    avQueuePlayer.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
    isObservingTimeControlStatus = true
  }

  override func removePlayerObservers() {
    if isObservingTimeControlStatus {
      avQueuePlayer.removeObserver(self, forKeyPath: "timeControlStatus")
      isObservingTimeControlStatus = false
    }
    super.removePlayerObservers()
  }

  override func buildPlayerQueue() { // no-override-state: the base resets lastKnownPosition to first-track-at-0.0 (OpenAccessPlayer:587); LCP must PRESERVE a restored position, so not assigning it is the correct behaviour here, not a dropped one
    resetPlayerQueue()
    isLoaded = false
  }

  /// Build player items preferring local decrypted files, falling back to streaming
  override public func buildPlayerItems(fromTracks tracks: [any Track]) -> [AVPlayerItem] {
    var items = [AVPlayerItem]()

    for (index, track) in tracks.enumerated() {
      if let lcpTrack = track as? LCPTrack,
         !forceStreamingTrackKeys.contains(track.key),
         let task = lcpTrack.downloadTask as? LCPDownloadTask,
         case let .saved(urls) = task.assetFileStatus(), !urls.isEmpty
      {
        let localItem: AVPlayerItem
        if urls.count == 1 {
          let asset = AVURLAsset(url: urls[0])
          localItem = AVPlayerItem(asset: asset)
        } else {
          if let compositionItem = createConcatenatedItem(from: urls) {
            localItem = compositionItem
          } else {
            let item = createStreamingPlayerItem(for: track, index: index)
            items.append(item)
            addEndObserver(for: item)
            continue
          }
        }
        localItem.audioTimePitchAlgorithm = .timeDomain
        localItem.trackIdentifier = track.key
        items.append(localItem)
        safeAddObserver(to: localItem)
      } else {
        let item = createStreamingPlayerItem(for: track, index: index)
        items.append(item)
        addEndObserver(for: item)
        ATLog(.debug, "🎵 Created STREAMING item for track \(index): fake://lcp-streaming/track/\(index)")
      }
    }

    return items
  }

  // MARK: - Navigation aligned with LCPPlayer
  
  override public func seekTo(position: TrackPosition, completion: ((TrackPosition?) -> Void)?) {
    let isSameTrackSeek = avQueuePlayer.currentItem?.trackIdentifier == position.track.key
    
    if isSameTrackSeek {
      isSeekingWithinSameTrack = true
    }
    
    super.seekTo(position: position) { [weak self] resultPosition in
      // Clear flag once seek completes
      if isSameTrackSeek {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self?.isSeekingWithinSameTrack = false
        }
      }
      completion?(resultPosition)
    }
  }

  /// LCP-specific callback implementation. Overrides the base
  /// `playCallback(at:completion:)` so the existing fast-path /
  /// rebuild logic still drives playback. The async protocol override
  /// (below) bridges into this through a continuation.
  override public func playCallback(at position: TrackPosition, completion: ((Error?) -> Void)?) {
    // Multiple async paths below — the 30s load-timeout work item, the
    // avQueuePlayer.seek callback, the rebuild-fallback, the target-not-found
    // branch — can all race to fire `completion`. If the timeout surfaces a
    // failure and the underlying seek later succeeds (or vice versa), the
    // `play(at:) async` bridge resumes its continuation twice and traps with
    // SWIFT TASK CONTINUATION MISUSE. Wrap once at entry so every downstream
    // call site is fire-at-most-once and thread-safe.
    let rawOnceCompletion = Self.makeOnceCompletion(completion)

    // PP-5205: ONE funnel for dropping the optimistic position, rather than a clear
    // at each exit.
    //
    // The first version of this fix cleared at the exits it could see: the timeout,
    // the two seek completions, the target-not-found branch. It missed the case it
    // was itself modelling — a seek to a chapter INSIDE the current track. That
    // changes no item, so the `.playing` observer's clear (gated on the current item
    // changing) never opened, and `currentTrackPosition` — which prefers this value —
    // froze at the target until the next track boundary, taking the timecodes and the
    // SAVED position with it. A frozen saved position is lost progress and lost
    // bookmarks, which is worse than the label lag this whole changeset is about.
    //
    // Every exit from `playCallback` already funnels through the fire-at-most-once
    // completion, so clearing here makes "an exit that forgets" unrepresentable
    // instead of merely fixed. The timeout path keeps its own explicit clear because
    // it publishes `.failed` BEFORE completing and must not do so with a stale
    // optimistic position still readable.
    // The clear sits OUTSIDE the once-gate on purpose. A superseded seek's late
    // callback therefore clears a NEWER seek's optimistic position — and that is the
    // right direction to fail: nil means "read the live player", which is at worst a
    // moment of truth. Moving it inside the gate would restore the freeze this exists
    // to prevent, so do not "tidy" it there.
    let onceCompletion: (Error?) -> Void = { [weak self] error in
      self?.queuedTrackPosition = nil
      rawOnceCompletion(error)
    }

    // PP-5205: publish the TARGET position immediately, before any queue work.
    //
    // `currentTrackPosition` already prefers `queuedTrackPosition` when a seek is in
    // flight (OpenAccessPlayer:91-94) precisely so the UI can render where the patron
    // is GOING rather than where the audio still is. The base class sets it on its own
    // seek path (:270); this override replaced that path wholesale and never did, so
    // for LCP the UI fell through to `avQueuePlayer.currentItem` — the PREVIOUS track.
    //
    // Symptom, reported on build 509: tap a chapter, the TOC dismisses, and the player
    // renders the chapter you just left for about a second before switching. The
    // full-screen "Downloading…" panel used to cover that second, so removing the panel
    // exposed it rather than caused it.
    //
    // Cleared when the new item actually starts (`timeControlStatus == .playing`) and
    // on every failure exit, so a stale optimistic position can never outlive the seek
    // that set it.
    queuedTrackPosition = position

    var needsRebuild = avQueuePlayer.items().isEmpty

    if !needsRebuild {
      if let targetIndex = avQueuePlayer.items().firstIndex(where: { $0.trackIdentifier == position.track.key }) {
        let item = avQueuePlayer.items()[targetIndex]
        let isCurrentlyLocal: Bool = {
          if let urlAsset = item.asset as? AVURLAsset {
            return urlAsset.url.isFileURL
          }
          return !(item.asset is AVURLAsset)
        }()
        if let lcpTrack = position.track as? LCPTrack {
          let shouldBeLocal = lcpTrack.hasLocalFiles() && !forceStreamingTrackKeys.contains(lcpTrack.key)
          if shouldBeLocal != isCurrentlyLocal {
            needsRebuild = true
          }
        }
      } else {
        needsRebuild = true
      }
    }

    let isSeekWithinSameTrack: Bool = {
      if needsRebuild { return false }
      if let currentItem = avQueuePlayer.currentItem,
         currentItem.trackIdentifier == position.track.key {
        return true
      }
      return false
    }()
    
    // Set flag BEFORE pausing to prevent race condition with observer
    isSeekingWithinSameTrack = isSeekWithinSameTrack
    
    // Now safe to pause
    avQueuePlayer.pause()
    (sharedResourceLoader as? LCPResourceLoaderDelegate)?.cancelAllRequests()
    
    // PP-5205: a seek to a chapter whose audio is ALREADY ON DISK is not a wait.
    //
    // The loading state used to be gated on `!isSeekWithinSameTrack` alone, which is
    // false for ANY track change — so choosing a later chapter muted the player and
    // published `isLoaded = false` even when every byte of that chapter was local.
    // Palace turned that into a full-screen "Downloading…" panel over a playing book
    // (PP-5205): a download announced for content already downloaded, with the audio
    // stopping while it was on screen.
    //
    // The common path is worse than it looks. With streaming ON the queue is built
    // from REMOTE assets before anything is local, and nothing re-queues when the
    // archive lands — `needsRebuild` is only ever evaluated here, inside
    // `playCallback(at:)`. So the first cross-track seek after a download completes
    // discovers the streaming/local mismatch and rebuilds. That rebuild is worth
    // doing, but over local file assets it is fast and needs no network: there is
    // nothing for the patron to wait ON, and so nothing to announce.
    //
    // Locality is the right question, not track identity. A seek to a track still
    // being STREAMED keeps the previous behaviour exactly — that one is a real wait,
    // and the mute is what stops the previous chapter bleeding over the buffer.
    // Asks the question `buildPlayerItem` asks, not a neighbouring one. It was fed
    // `hasLocalFiles()` — "the decrypted URLs exist on disk" — while the builder
    // gates on `assetFileStatus() == .saved(urls)` with a non-empty list (:630-634).
    // Two predicates over the same fact disagree eventually, and here the
    // disagreement would declare a wait over before the item that serves it exists.
    let targetIsLocallyPlayable: Bool = {
      guard let lcpTrack = position.track as? LCPTrack,
            let task = lcpTrack.downloadTask as? LCPDownloadTask,
            case let .saved(urls) = task.assetFileStatus()
      else { return false }
      return Self.trackIsLocallyPlayable(
        hasSavedAssets: !urls.isEmpty,
        isForcedToStream: forceStreamingTrackKeys.contains(lcpTrack.key)
      )
    }()

    if !isSeekWithinSameTrack && !targetIsLocallyPlayable {
      isLoaded = false
      suppressAudibleUntilPlaying = true
      avQueuePlayer.isMuted = true
      lastStartedItemKey = nil

      // Cancel any prior fallback from an earlier play(at:) so stale timers don't
      // fire after the queue has advanced past the startup window. Without this,
      // rapid re-presentations stack multiple timers that all log at once.
      loadTimeoutWorkItem?.cancel()
      let timeoutPosition = position
      let workItem = DispatchWorkItem { [weak self] in
        guard let self = self, !self.isLoaded else { return }
        ATLog(.warn, "LCPStreamingPlayer: Publication loading timeout — surfacing failure so caller can show an alert and release the open lock")
        self.isLoaded = true
        self.suppressAudibleUntilPlaying = false
        self.avQueuePlayer.isMuted = false

        // Emit a playback failure so AudiobookManager → Palace surfaces the
        // "Audiobook Unavailable" alert and the BookService open lock releases
        // instead of latching. Without this, a stalled resource loader looks
        // identical to a successful open from the UI's perspective.
        let timeoutError = NSError(
          domain: "LCPStreamingPlayer",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for LCP publication to load"]
        )
        // PP-5205: the seek never landed, so the optimistic position must not
        // outlive it. Leaving it set would have the UI — and position reporting,
        // which drives bookmarks and progress sync — claim a chapter that never
        // started playing.
        self.queuedTrackPosition = nil
        self.playbackStatePublisher.send(.failed(timeoutPosition, timeoutError))
        onceCompletion(timeoutError)
      }
      loadTimeoutWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: workItem)
    } else if !isSeekWithinSameTrack {
      // PP-5205: a local cross-track seek arms NO load timeout — there is no load to
      // time out. But a timer armed by an EARLIER streaming seek may still be in
      // flight, and letting it fire here would surface "Audiobook Unavailable" over a
      // book that is playing fine from disk. Cancel it, and make sure the audible
      // suppression from that earlier seek cannot outlive it either.
      loadTimeoutWorkItem?.cancel()
      loadTimeoutWorkItem = nil
      if suppressAudibleUntilPlaying {
        suppressAudibleUntilPlaying = false
        avQueuePlayer.isMuted = false
      }
      isLoaded = true

      // PP-5205 round 3: a LOCAL seek that still needs a queue rebuild is not a
      // no-wait, and the first version of this branch left it with no failure path
      // at all.
      //
      // `needsRebuild` is decided by the SAME locality expression (:222-226), so the
      // streaming→local transition — the common path this whole change is about —
      // always lands here AND rebuilds. The rebuild can still produce a streaming
      // item: `buildPlayerItem` falls back to one when a multi-URL composition
      // fails, which `assetFileStatus()` cannot predict. Its seek completion
      // publishes `.started` on failure, never `.failed`. So without a backstop a
      // failed rebuild is indistinguishable from success: no alert, no Retry, and
      // the host's open lock never released.
      //
      // NO failure backstop on this path, and that is a KNOWN GAP, not an oversight.
      //
      // The streaming branch above arms a 30s timer; this branch does not, so if the
      // queue rebuild below fails, nothing surfaces it: the rebuild publishes
      // `.started` even when its seek fails (:484-489), so a failed rebuild is
      // indistinguishable from a successful one — no alert, no Retry, and the host's
      // open lock is never released.
      //
      // A guard was attempted three times (#228, #229) and was wrong three times, each
      // time on a predicate ADJACENT to the one that matters: playback state where the
      // question was queue state, then queue CONTENTS where the question was whether
      // NAVIGATION landed — the rebuild inserts the target item first (:455), so
      // `currentItem == target && readyToPlay` is already true before the seek runs.
      // It was reverted rather than attempted a fourth time on a release candidate.
      //
      // The right signal is the rebuild's own seek completion, which is where a guard
      // belongs when this is done properly. See PP-5211.
    }

    if !needsRebuild {
      let queueItems = avQueuePlayer.items()
      if let targetIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
        let currentIndex = queueItems.firstIndex(where: { $0 == avQueuePlayer.currentItem }) ?? 0
        if targetIndex > currentIndex {
          for _ in currentIndex..<targetIndex { avQueuePlayer.advanceToNextItem() }
        }
        let safeTs = safeTimestamp(for: position)
        let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] success in
          guard let self = self else {
            return
          }

          if !success {
            ATLog(.error, "🎵 [LCPStreamingPlayer] Seek failed — rebuilding queue to recover position")
            // Seek failure can cause position drift. Rebuild the queue to force correct positioning
            // rather than silently continuing at the wrong position.
            rebuildPlayerQueueAndNavigate(to: position, shouldResumePlayback: true) { _ in
              onceCompletion(nil)
            }
            return
          }

          // Ensure session is active before resuming
          do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
          } catch {
            ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session: \(error)")
          }

          avQueuePlayer.play()
          restorePlaybackRate()

          if !isSeekWithinSameTrack {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
              if let self = self, !self.isLoaded {
                isLoaded = true
                suppressAudibleUntilPlaying = false
                avQueuePlayer.isMuted = false
                self.loadTimeoutWorkItem?.cancel()
              }
            }
          } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
              self?.isSeekingWithinSameTrack = false
            }
          }

          onceCompletion(nil)
        }
        return
      }
    }

    // Clear seek flag before rebuilding queue
    isSeekingWithinSameTrack = false
    
    let allTracks = tableOfContents.allTracks
    avQueuePlayer.removeAllItems()

    // Find target track index for windowing
    let targetTrackIndex = allTracks.firstIndex { $0.key == position.track.key } ?? 0

    // Add the target item FIRST so currentItem immediately reflects the intended chapter
    if targetTrackIndex < allTracks.count {
      let targetTrack = allTracks[targetTrackIndex]
      let targetItem = buildPlayerItem(for: targetTrack, index: targetTrackIndex)
      avQueuePlayer.insert(targetItem, after: nil)
      addEndObserver(for: targetItem)
    }
    // Then add a window of neighboring items lazily
    let windowSize = 5
    let startIndex = max(0, targetTrackIndex - 1)
    let endIndex = min(allTracks.count - 1, targetTrackIndex + windowSize)
    for i in startIndex...endIndex where i != targetTrackIndex {
      let track = allTracks[i]
      let item = buildPlayerItem(for: track, index: i)
      avQueuePlayer.insert(item, after: nil)
      addEndObserver(for: item)
    }

    let queueItems = avQueuePlayer.items()
    if let targetQueueIndex = queueItems.firstIndex(where: { $0.trackIdentifier == position.track.key }) {
      for _ in 0..<targetQueueIndex { avQueuePlayer.advanceToNextItem() }
      let safeTs = safeTimestamp(for: position)
      let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
      let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
      avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] success in
        guard let self = self else {
          return
        }

        if !success {
          ATLog(.error, "🎵 [LCPStreamingPlayer] Seek failed in queue rebuild — position may be inaccurate, notifying playback state")
          // Notify observers that the seek didn't land precisely so position can be corrected
          if let currentPos = currentTrackPosition {
            playbackStatePublisher.send(.started(currentPos))
          }
        }

        do {
          let session = AVAudioSession.sharedInstance()
          try session.setActive(true)
          ATLog(
            .debug,
            "🔊 [LCPStreamingPlayer] Audio route (lazy window): \(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", "))"
          )
        } catch {
          ATLog(.error, "🔊 [LCPStreamingPlayer] Failed to activate audio session (lazy window): \(error)")
        }

        avQueuePlayer.play()
        restorePlaybackRate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
          if let self = self, !self.isLoaded {
            isLoaded = true
            suppressAudibleUntilPlaying = false
            avQueuePlayer.isMuted = false
          }
        }

        onceCompletion(nil)
      }
    } else {
      onceCompletion(NSError(
        domain: "LCPStreamingPlayer",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Target track not found in queue"]
      ))
    }
  }

  override public func rebuildPlayerQueueAndNavigate(
    to trackPosition: TrackPosition?,
    shouldResumePlayback: Bool = true,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard let position = trackPosition else {
      completion?(false); return
    }
    let wasPlaying = avQueuePlayer.rate > 0
    avQueuePlayer.pause()
    (sharedResourceLoader as? LCPResourceLoaderDelegate)?.cancelAllRequests()
    isLoaded = false

    let allTracks = tableOfContents.allTracks
    resetPlayerQueue()

    guard let targetTrackIndex = allTracks.firstIndex(where: { $0.key == position.track.key }) else {
      completion?(false)
      return
    }

    let targetTrack = allTracks[targetTrackIndex]
    let targetItem = buildPlayerItem(for: targetTrack, index: targetTrackIndex)
    avQueuePlayer.insert(targetItem, after: nil)
    addEndObserver(for: targetItem)

    let windowSize = 5
    let startIndex = max(0, targetTrackIndex - 1)
    let endIndex = min(allTracks.count - 1, targetTrackIndex + windowSize)
    for i in startIndex...endIndex where i != targetTrackIndex {
      let track = allTracks[i]
      let item = buildPlayerItem(for: track, index: i)
      avQueuePlayer.insert(item, after: nil)
      addEndObserver(for: item)
    }

    let safeTs = safeTimestamp(for: position)
    let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    if let targetQueueIndex = avQueuePlayer.items().firstIndex(where: { $0.trackIdentifier == position.track.key }) {
      for _ in 0..<targetQueueIndex { avQueuePlayer.advanceToNextItem() }
      avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] _ in
        guard let self else {
          completion?(false); return
        }
        if wasPlaying && shouldResumePlayback {
          suppressAudibleUntilPlaying = true
          avQueuePlayer.isMuted = true
          avQueuePlayer.play()
          restorePlaybackRate()
        }
        completion?(true)
      }
    } else {
      completion?(false)
    }
  }

  override public func move(to value: Double) async -> TrackPosition? {
    guard let currentTrackPosition,
          let currentChapter = try? tableOfContents.chapter(forPosition: currentTrackPosition)
    else {
      return currentTrackPosition
    }

    let chapterDuration = currentChapter.duration ?? 0.0
    let offset = value * chapterDuration
    var newPosition = currentTrackPosition
    newPosition.timestamp = offset

    let safeTs = safeTimestamp(for: newPosition)
    newPosition.timestamp = safeTs
    let seekTime = CMTime(seconds: safeTs, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    let tolerance = CMTime(seconds: 0.15, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    return await withCheckedContinuation { (continuation: CheckedContinuation<TrackPosition?, Never>) in
      avQueuePlayer.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: .zero) { [weak self] _ in
        if let self, avQueuePlayer.rate > 0 {
          avQueuePlayer.play()
        }
        continuation.resume(returning: newPosition)
      }
    }
  }

  // MARK: - Helpers

  /// Whether a seek target can be played from disk RIGHT NOW — the predicate that
  /// decides whether a chapter change is a wait worth announcing (PP-5205).
  ///
  /// Extracted from the call site and made static so it can be table-tested: it
  /// carries the headline behaviour of this ticket and needs no AVFoundation, unlike
  /// the rest of `playCallback`. Having the assets is necessary but not sufficient —
  /// a track in `forceStreamingTrackKeys` has been deliberately pushed onto the
  /// streaming path (a failed local open, say) and must keep the streaming
  /// behaviour, mute included, even though its files are present.
  ///
  /// NOT sufficient on its own for "no wait": `buildPlayerItem` can still fall back
  /// to a streaming item when a multi-URL composition fails, which no predicate over
  /// file state can foresee. The `needsRebuild` backstop in `playCallback` covers
  /// that residue.
  nonisolated static func trackIsLocallyPlayable(hasSavedAssets: Bool, isForcedToStream: Bool) -> Bool {
    hasSavedAssets && !isForcedToStream
  }

  /// Wraps an optional `(Error?) -> Void` completion in a thread-safe,
  /// fire-at-most-once closure. Required because `playCallback` has multiple
  /// racing async paths (timeout work item, seek callback, rebuild fallback)
  /// that can each invoke the caller's completion; the upstream `play(at:)`
  /// async bridge resumes a CheckedContinuation and traps on a second resume.
  /// Returns a non-optional closure so call sites stay simple even when the
  /// caller passed `nil`.
  static func makeOnceCompletion(_ completion: ((Error?) -> Void)?) -> (Error?) -> Void {
    let lock = NSLock()
    var fired = false
    return { error in
      lock.lock()
      let shouldFire = !fired
      fired = true
      lock.unlock()
      if shouldFire {
        completion?(error)
      }
    }
  }

  private func safeTimestamp(for position: TrackPosition) -> TimeInterval {
    let duration = position.track.duration

    let epsilon: TimeInterval = 0.1

    if position.timestamp >= duration {
      return max(0, duration - epsilon)
    }

    return max(0, min(position.timestamp, duration - epsilon))
  }

  // Build a single AVPlayerItem by concatenating multiple local parts
  private func createConcatenatedItem(from urls: [URL]) -> AVPlayerItem? {
    let composition = AVMutableComposition()
    guard let compositionAudioTrack = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      return nil
    }
    var currentInsertTime = CMTime.zero
    for url in urls {
      let asset = AVURLAsset(url: url)
      guard let track = asset.tracks(withMediaType: .audio).first else {
        continue
      }
      let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      do {
        try compositionAudioTrack.insertTimeRange(timeRange, of: track, at: currentInsertTime)
        currentInsertTime = CMTimeAdd(currentInsertTime, asset.duration)
      } catch {
        ATLog(.error, "Failed to build composition: \(error)")
        return nil
      }
    }
    let item = AVPlayerItem(asset: composition)
    // PP-4518: preserve narrator pitch across the full 0.5×–3.0× range.
    item.audioTimePitchAlgorithm = .timeDomain
    return item
  }

  // Build a single item for a specific index using the same priority: local file -> streaming -> placeholder
  private func buildPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
    if let lcpTrack = track as? LCPTrack,
       !forceStreamingTrackKeys.contains(track.key),
       let task = lcpTrack.downloadTask as? LCPDownloadTask,
       case let .saved(urls) = task.assetFileStatus(), !urls.isEmpty
    {
      if urls.count == 1 {
        let asset = AVURLAsset(url: urls[0])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        item.trackIdentifier = track.key
        safeAddObserver(to: item)
        return item
      } else if let compositionItem = createConcatenatedItem(from: urls) {
        compositionItem.audioTimePitchAlgorithm = .timeDomain
        compositionItem.trackIdentifier = track.key
        safeAddObserver(to: compositionItem)
        return compositionItem
      }
    }

    let item = createStreamingPlayerItem(for: track, index: index)
    return item
  }

  private func createStreamingPlayerItem(for track: any Track, index: Int) -> AVPlayerItem {
    let assetURL: URL = {
      if let publication = streamingProvider?.getPublication(), index < publication.readingOrder.count {
        let readingOrderLink = publication.readingOrder[index]
        let customURL = URL(string: "readium-lcp://track\(index)/\(readingOrderLink.href)")!
        ATLog(.debug, "🎵 Creating streaming item \(index) with custom URL: \(customURL.absoluteString)")
        return customURL
      } else {
        ATLog(.debug, "🎵 Creating streaming item \(index) with fallback URL (no publication)")
        return URL(string: "fake://lcp-streaming/track/\(index)")!
      }
    }()

    let assetOptions: [String: Any] = [
      AVURLAssetPreferPreciseDurationAndTimingKey: false
    ]
    let asset = AVURLAsset(url: assetURL, options: assetOptions)

    if let sharedResourceLoader = sharedResourceLoader {
      objc_setAssociatedObject(
        asset,
        Self.resourceLoaderAssocKey.rawValue,
        sharedResourceLoader,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
      asset.resourceLoader.setDelegate(sharedResourceLoader, queue: resourceLoaderQueue)
      ATLog(.debug, "🎵 Resource loader delegate set for track \(index)")
    } else {
      ATLog(.error, "🎵 ERROR: No resource loader available for track \(index)!")
    }

    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain
    item.trackIdentifier = track.key
    item.preferredForwardBufferDuration = 0.5
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

    safeAddObserver(to: item)

    return item
  }

  // Inherit all the KVO management from LCPPlayer
  private var observedItems = Set<ObjectIdentifier>()
  private let observerQueue = DispatchQueue(label: "com.palace.lcp-streaming-observer", qos: .utility)

  private func safeAddObserver(to item: AVPlayerItem) {
    observerQueue.async { [weak self, weak item] in
      guard let self = self, let item = item else {
        return
      }
      let itemId = ObjectIdentifier(item)
      guard !observedItems.contains(itemId) else {
        return
      }

      item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
      observedItems.insert(itemId)
    }
  }

  override public func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    if keyPath == "timeControlStatus", let player = object as? AVQueuePlayer {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        
        switch player.timeControlStatus {
        case .playing:
          self.isLoaded = true
          loadTimeoutWorkItem?.cancel()
          loadTimeoutWorkItem = nil
          if suppressAudibleUntilPlaying {
            avQueuePlayer.isMuted = false
            suppressAudibleUntilPlaying = false
          }
          if let currentKey = avQueuePlayer.currentItem?.trackIdentifier, lastStartedItemKey != currentKey {
            lastStartedItemKey = currentKey
            // PP-5205: the real item is now playing, so the optimistic position has
            // served its purpose — drop it and let `currentTrackPosition` derive from
            // the live queue again.
            queuedTrackPosition = nil
            if let pos = currentTrackPosition {
              playbackStatePublisher.send(.started(pos))
            }
          }
          if isSeekingWithinSameTrack {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
              self?.isSeekingWithinSameTrack = false
            }
          }
        case .waitingToPlayAtSpecifiedRate:
          // AVPlayer enters this state for ordinary mid-playback buffering, not just
          // initial load. Only treat it as "not loaded" while we've never confirmed
          // `.playing` for the current play(at:) call — otherwise every LCP decrypt
          // gap re-mutes the player and leaves the user on a silent spinner.
          if lastStartedItemKey == nil, !isSeekingWithinSameTrack {
            self.isLoaded = false
            if !self.avQueuePlayer.isMuted {
              avQueuePlayer.isMuted = true
              suppressAudibleUntilPlaying = true
            }
          }
        default:
          break
        }
      }
      return
    }

    guard keyPath == "status",
          let item = object as? AVPlayerItem
    else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }

    DispatchQueue.main.async { [weak self] in
      switch item.status {
      case .readyToPlay:
        if let currentItem = self?.avQueuePlayer.currentItem, currentItem == item {
          // Defer isLoaded to timeControlStatus changes to avoid premature hiding of loading view
        }
      case .failed:
        if let key = item.trackIdentifier {
          self?.forceStreamingTrackKeys.insert(key)
          self?.rebuildPlayerQueueAndNavigate(to: self?.currentTrackPosition)
        }
      case .unknown:
        break
      @unknown default:
        break
      }
    }
  }

  // MARK: - Chapter Position Tracking for Multi-Track Chapters

  @objc override func playerItemDidReachEnd(_ notification: Notification) {
    guard let endedItem = notification.object as? AVPlayerItem,
          let endedTrackKey = endedItem.trackIdentifier,
          let endedTrack = tableOfContents.track(forKey: endedTrackKey)
    else {
      return
    }

    let endedPosition = TrackPosition(track: endedTrack, timestamp: endedTrack.duration, tracks: tableOfContents.tracks)
    // See `OpenAccessPlayer.playerItemDidReachEnd` — same handler, same reason.
    let currentChapter = try? tableOfContents.chapter(
      forPosition: endedPosition, preferChapterEndingHere: true
    )

    if let nextTrack = tableOfContents.tracks.nextTrack(endedTrack) {
      let nextStart = TrackPosition(track: nextTrack, timestamp: 0.0, tracks: tableOfContents.tracks)
      // Unpinned while the ended side stays pinned — see the note in
      // `OpenAccessPlayer`'s end-of-track handler. The asymmetry is what makes
      // a real chapter ending distinguishable from a chapter that merely spans
      // two tracks.
      let nextChapter = try? tableOfContents.chapter(forPosition: nextStart)

      if let cur = currentChapter, let nxt = nextChapter, cur == nxt {
        // Same chapter continues on next track - navigate explicitly
        // CRITICAL: Don't use advanceToNextItem() - AVQueuePlayer's internal order
        // may not match our logical track order
        playCallback(at: nextStart, completion: nil)
        return
      } else {
        // Different chapters - let parent handle chapter transition
        super.playerItemDidReachEnd(notification)
        return
      }
    } else {
      // No next track - end of book
      handlePlaybackEnd(currentTrack: endedTrack, completion: nil)
      return
    }
  }

  // MARK: - End of Book Handling

  override func handlePlaybackEnd(currentTrack _: any Track, completion: ((TrackPosition?) -> Void)?) {
    // 1. Publish book completed event
    playbackStatePublisher.send(.bookCompleted)
    
    guard let firstTrack = tableOfContents.tracks.first else {
      completion?(nil)
      return
    }
    
    // Create position at the beginning (first track, timestamp 0)
    let beginningPosition = TrackPosition(
      track: firstTrack,
      timestamp: 0.0,
      tracks: tableOfContents.tracks
    )
    
    // 2. Seek to the beginning position
    seekTo(position: beginningPosition) { [weak self] finalPosition in
      guard let self = self else {
        completion?(nil)
        return
      }
      
      // 3. Pause at the beginning
      self.avQueuePlayer.pause()
      self.lastKnownPosition = beginningPosition
      
      // 4. Trigger player view update
      DispatchQueue.main.async {
        self.playbackStatePublisher.send(.stopped(beginningPosition))
      }
      
      completion?(finalPosition)
    }
  }

  func publicationDidLoad() {
    ATLog(.debug, "🎵 [LCPStreamingPlayer] Publication loaded - enabling streaming")
    if !isLoaded && avQueuePlayer.items().isEmpty {
      buildPlayerQueue()
    }
  }

  // No `deinit`. `LCPResourceLoaderDelegate` now cancels its own in-flight
  // requests and timeout guards when it deallocates, so there is nothing here
  // to reach across for.

  override func unload() {
    super.unload()
    (sharedResourceLoader as? LCPResourceLoaderDelegate)?.shutdown()
    streamingProvider = nil
  }
}
