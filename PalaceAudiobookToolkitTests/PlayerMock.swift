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

  func skipPlayhead(_: TimeInterval, completion: ((PalaceAudiobookToolkit.TrackPosition?) -> Void)?) {
    completion?(currentTrackPosition)
  }

  func play(at _: PalaceAudiobookToolkit.TrackPosition, completion: (((any Error)?) -> Void)?) {
    completion?(nil)
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

  func playAtLocation(_: TrackPosition, completion _: Completion?) {}

  func movePlayheadToLocation(_: TrackPosition, completion _: Completion?) {}
  func move(to _: Double, completion _: ((PalaceAudiobookToolkit.TrackPosition?) -> Void)?) {}
}
