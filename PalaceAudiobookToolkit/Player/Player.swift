//
//  Player.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/1/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation

// MARK: - PlaybackRate

public enum PlaybackRate: Int, CaseIterable {
  case threeQuartersTime = 75
  case normalTime = 100
  case oneAndAQuarterTime = 125
  case oneAndAHalfTime = 150
  case doubleTime = 200

  public static func convert(rate: PlaybackRate) -> Float {
    Float(rate.rawValue) * 0.01
  }
}

// MARK: - PlaybackState

public enum PlaybackState {
  case started(TrackPosition)
  case stopped(TrackPosition)
  case failed(TrackPosition?, Error?)
  case completed(Chapter)
  case bookCompleted
  case unloaded
}

// MARK: - Player

public protocol Player: NSObject {
  typealias Completion = (Error?) -> Void

  var isPlaying: Bool { get }
  var queuesEvents: Bool { get }
  var isDrmOk: Bool { get set }
  var currentOffset: Double { get }
  var tableOfContents: AudiobookTableOfContents { get }
  var currentTrackPosition: TrackPosition? { get }
  var currentChapter: Chapter? { get }
  var playbackRate: PlaybackRate { get set }
  var isLoaded: Bool { get }
  var playbackStatePublisher: PassthroughSubject<PlaybackState, Never> { get }

  init?(tableOfContents: AudiobookTableOfContents)
  func play()
  func pause()
  func unload()
  func skipPlayhead(_ timeInterval: TimeInterval, completion: ((TrackPosition?) -> Void)?)
  func play(at position: TrackPosition, completion: ((Error?) -> Void)?)
  func move(to value: Double, completion: ((TrackPosition?) -> Void)?)
}

extension Player {
  func savePlaybackRate(rate: PlaybackRate) {
    UserDefaults.standard.set(rate.rawValue, forKey: "playback_rate")
  }

  func fetchPlaybackRate() -> PlaybackRate? {
    guard let rate = UserDefaults.standard.value(forKey: "playback_rate") as? Int else {
      return nil
    }
    return PlaybackRate(rawValue: rate)
  }
}
