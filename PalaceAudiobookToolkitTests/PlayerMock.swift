//
//  PlayerMock.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Dean Silfen on 3/7/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Combine
import PalaceAudiobookToolkit
import UIKit

class PlayerMock: NSObject, Player {
  var currentOffset: Double = 0
  var isPlaying: Bool = false
  var queuesEvents: Bool = false
  var isDrmOk: Bool = true
  var isLoaded: Bool = false
  var tableOfContents: PalaceAudiobookToolkit.AudiobookTableOfContents
  var currentTrackPosition: PalaceAudiobookToolkit.TrackPosition?
  var playbackRate: PalaceAudiobookToolkit.PlaybackRate = .normalTime
  var playbackStatePublisher: PassthroughSubject<PalaceAudiobookToolkit.PlaybackState, Never> = PassthroughSubject()
  var currentChapter: PalaceAudiobookToolkit.Chapter?
  
  // Fast UI position updates publisher (required by Player protocol)
  private let positionSubject = PassthroughSubject<PalaceAudiobookToolkit.TrackPosition, Never>()
  var positionPublisher: AnyPublisher<PalaceAudiobookToolkit.TrackPosition, Never> {
    positionSubject.eraseToAnyPublisher()
  }

  required init(tableOfContents: PalaceAudiobookToolkit.AudiobookTableOfContents) {
    self.tableOfContents = tableOfContents
    playbackStatePublisher = PassthroughSubject()
  }

  // MARK: - Recorded calls (spy)

  private(set) var skipPlayheadCalls: [TimeInterval] = []
  private(set) var playAtCalls: [PalaceAudiobookToolkit.TrackPosition] = []
  private(set) var moveToCalls: [Double] = []

  // MARK: - Programmable return values

  /// If non-nil, `play(at:)` will throw this error instead of returning.
  var playAtError: Error?
  /// If non-nil, `skipPlayhead` returns this. Otherwise returns `currentTrackPosition`.
  var skipPlayheadResult: PalaceAudiobookToolkit.TrackPosition??
  /// If non-nil, `move(to:)` returns this. Otherwise returns `currentTrackPosition`.
  var moveToResult: PalaceAudiobookToolkit.TrackPosition??

  func skipPlayhead(_ timeInterval: TimeInterval) async -> PalaceAudiobookToolkit.TrackPosition? {
    skipPlayheadCalls.append(timeInterval)
    if let override = skipPlayheadResult {
      return override
    }
    return currentTrackPosition
  }

  func play(at position: PalaceAudiobookToolkit.TrackPosition) async throws {
    playAtCalls.append(position)
    if let error = playAtError {
      throw error
    }
    isPlaying = true
    currentTrackPosition = position
  }

  func move(to value: Double) async -> PalaceAudiobookToolkit.TrackPosition? {
    moveToCalls.append(value)
    if let override = moveToResult {
      return override
    }
    return currentTrackPosition
  }

  func play() {
    isPlaying = true
  }

  func pause() {
    isPlaying = false
  }

  func unload() {
    isPlaying = false
  }
}
