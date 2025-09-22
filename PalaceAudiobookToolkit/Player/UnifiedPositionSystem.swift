//
//  UnifiedPositionSystem.swift
//  PalaceAudiobookToolkit
//
//  Created by Palace Team on 2024-09-21.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import Combine

// MARK: - Position Calculation Protocol

/// Protocol defining unified position calculations for all audiobook types
/// Eliminates inconsistencies between different player implementations
public protocol PositionCalculating {
    func chapterOffset(from position: TrackPosition, chapter: Chapter) -> TimeInterval
    func chapterProgress(from position: TrackPosition, chapter: Chapter) -> Double
    func totalBookProgress(from position: TrackPosition, tableOfContents: AudiobookTableOfContents) -> Double
    func validatePosition(_ position: TrackPosition, within chapter: Chapter) -> TrackPosition
    func calculateSeekPosition(sliderValue: Double, within chapter: Chapter) -> TrackPosition
}

/// Production implementation of unified position calculations
/// Single source of truth for all audiobook position math
public class UnifiedPositionCalculator: PositionCalculating {
    
    public init() {}
    
    public func chapterOffset(from position: TrackPosition, chapter: Chapter) -> TimeInterval {
        do {
            let offset = try position - chapter.position
            return max(0.0, offset) // Ensure non-negative
        } catch {
            ATLog(.error, "Position calculation failed: \(error.localizedDescription)")
            return 0.0
        }
    }
    
    public func chapterProgress(from position: TrackPosition, chapter: Chapter) -> Double {
        let chapterDuration = chapter.duration ?? chapter.position.track.duration
        guard chapterDuration > 0 else { return 0.0 }
        
        let offset = chapterOffset(from: position, chapter: chapter)
        return min(1.0, max(0.0, offset / chapterDuration))
    }
    
    public func totalBookProgress(from position: TrackPosition, tableOfContents: AudiobookTableOfContents) -> Double {
        let totalDuration = tableOfContents.tracks.totalDuration
        guard totalDuration > 0 else { return 0.0 }
        
        let currentDuration = position.durationToSelf()
        return min(1.0, max(0.0, currentDuration / totalDuration))
    }
    
    public func validatePosition(_ position: TrackPosition, within chapter: Chapter) -> TrackPosition {
        let chapterStart = chapter.position.timestamp
        let chapterDuration = chapter.duration ?? chapter.position.track.duration
        let chapterEnd = chapterStart + chapterDuration
        let trackDuration = chapter.position.track.duration
        
        // Clamp within both chapter and track boundaries
        let maxAllowed = min(chapterEnd, trackDuration)
        let clampedTimestamp = max(chapterStart, min(position.timestamp, maxAllowed))
        
        return TrackPosition(
            track: chapter.position.track,
            timestamp: clampedTimestamp,
            tracks: position.tracks
        )
    }
    
    public func calculateSeekPosition(sliderValue: Double, within chapter: Chapter) -> TrackPosition {
        let chapterDuration = chapter.duration ?? chapter.position.track.duration
        let chapterStartTimestamp = chapter.position.timestamp
        
        // Calculate position within chapter
        let offsetWithinChapter = sliderValue * chapterDuration
        let absoluteTimestamp = chapterStartTimestamp + offsetWithinChapter
        
        // Create and validate position
        let proposedPosition = TrackPosition(
            track: chapter.position.track,
            timestamp: absoluteTimestamp,
            tracks: chapter.position.tracks
        )
        
        return validatePosition(proposedPosition, within: chapter)
    }
}

// MARK: - Reactive Player State Management

/// Modern reactive state management for audiobook players
/// Provides single source of truth for all player state
@MainActor
public class ReactivePlayerStateManager: ObservableObject {
    
    // MARK: - Published State
    @Published public var currentPosition: TrackPosition?
    @Published public var currentChapter: Chapter?
    @Published public var chapterProgress: Double = 0.0
    @Published public var totalProgress: Double = 0.0
    @Published public var isPlaying: Bool = false
    @Published public var isLoaded: Bool = false
    @Published public var currentChapterTitle: String = ""
    @Published public var timeRemaining: TimeInterval = 0.0
    
    // MARK: - Dependencies
    private let tableOfContents: AudiobookTableOfContents
    private let positionCalculator: PositionCalculating
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - State Publishers
    public let stateUpdatePublisher = PassthroughSubject<PlayerStateUpdate, Never>()
    public let seekingEventPublisher = PassthroughSubject<SeekingEvent, Never>()
    
    public init(tableOfContents: AudiobookTableOfContents, positionCalculator: PositionCalculating = UnifiedPositionCalculator()) {
        self.tableOfContents = tableOfContents
        self.positionCalculator = positionCalculator
        setupReactiveBindings()
        
        ATLog(.info, "ReactivePlayerStateManager initialized")
    }
    
    // MARK: - State Update Methods
    
    public func updatePosition(_ position: TrackPosition) {
        let oldChapter = currentChapter
        currentPosition = position
        
        // Update chapter if position changed significantly
        if let chapter = try? tableOfContents.chapter(forPosition: position) {
            if currentChapter?.id != chapter.id {
                currentChapter = chapter
                currentChapterTitle = chapter.title
                
                ATLog(.info, "Chapter changed: \(oldChapter?.title ?? "nil") → \(chapter.title)")
                stateUpdatePublisher.send(.chapterChanged(chapter))
            }
        }
        
        updateCalculatedState()
        stateUpdatePublisher.send(.positionChanged(position))
    }
    
    public func updatePlaybackState(_ playing: Bool) {
        isPlaying = playing
        stateUpdatePublisher.send(.playbackStateChanged(playing ? .playing : .paused))
    }
    
    public func updateLoadedState(_ loaded: Bool) {
        isLoaded = loaded
    }
    
    // MARK: - Seeking Interface
    
    public func requestSeek(sliderValue: Double) -> TrackPosition? {
        guard let chapter = currentChapter else {
            ATLog(.error, "Cannot seek: no current chapter")
            return nil
        }
        
        let targetPosition = positionCalculator.calculateSeekPosition(sliderValue: sliderValue, within: chapter)
        
        let seekingEvent = SeekingEvent(
            type: .sliderSeek,
            from: currentPosition,
            to: targetPosition,
            sliderValue: sliderValue,
            chapterTitle: chapter.title
        )
        
        seekingEventPublisher.send(seekingEvent)
        return targetPosition
    }
    
    // MARK: - Private Implementation
    
    private func setupReactiveBindings() {
        // Update calculated state when position changes
        $currentPosition
            .compactMap { $0 }
            .removeDuplicates { abs($0.timestamp - $1.timestamp) < 0.1 }
            .sink { [weak self] _ in
                self?.updateCalculatedState()
            }
            .store(in: &cancellables)
    }
    
    private func updateCalculatedState() {
        guard let position = currentPosition, let chapter = currentChapter else {
            chapterProgress = 0.0
            totalProgress = 0.0
            timeRemaining = 0.0
            return
        }
        
        chapterProgress = positionCalculator.chapterProgress(from: position, chapter: chapter)
        totalProgress = positionCalculator.totalBookProgress(from: position, tableOfContents: tableOfContents)
        
        let totalDuration = tableOfContents.tracks.totalDuration
        let currentDuration = position.durationToSelf()
        timeRemaining = max(0, totalDuration - currentDuration)
    }
}

// MARK: - State Update Types

public enum PlayerStateUpdate {
    case positionChanged(TrackPosition)
    case chapterChanged(Chapter)
    case playbackStateChanged(PlayerPlaybackState)
}

public enum PlayerPlaybackState {
    case playing
    case paused
    case loading
    case error(Error)
}

public struct SeekingEvent {
    let type: SeekingType
    let from: TrackPosition?
    let to: TrackPosition
    let sliderValue: Double?
    let chapterTitle: String
    let timestamp: Date = Date()
    
    enum SeekingType {
        case sliderSeek
        case skipForward
        case skipBackward
        case chapterNavigation
    }
}
