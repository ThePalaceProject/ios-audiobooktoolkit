//
// Player.swift
// PalaceAudiobookToolkit
//
// Created by Maurice Carrier on 4/1/24.
// Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import Foundation

// MARK: - PlaybackRate

public enum PlaybackRate: Int, CaseIterable {
  // Core preset cases (used for cycling, CarPlay, remote controls)
  case threeQuartersTime = 75
  case normalTime = 100
  case oneAndAQuarterTime = 125
  case oneAndAHalfTime = 150
  case doubleTime = 200

  // Intermediate 0.05× steps
  case p080 = 80
  case p085 = 85
  case p090 = 90
  case p095 = 95
  case p105 = 105
  case p110 = 110
  case p115 = 115
  case p120 = 120
  case p130 = 130
  case p135 = 135
  case p140 = 140
  case p145 = 145
  case p155 = 155
  case p160 = 160
  case p165 = 165
  case p170 = 170
  case p175 = 175
  case p180 = 180
  case p185 = 185
  case p190 = 190
  case p195 = 195

  public static func convert(rate: PlaybackRate) -> Float {
    Float(rate.rawValue) * 0.01
  }

  /// Named preset rates shown as quick-select chips in the speed picker UI
  public static let presets: [PlaybackRate] = [
    .threeQuartersTime, .normalTime, .oneAndAQuarterTime, .oneAndAHalfTime, .doubleTime
  ]

  /// All available steps in ascending order (0.75× → 2.0×)
  public static let steps: [PlaybackRate] = PlaybackRate.allCases.sorted { $0.rawValue < $1.rawValue }

  /// Returns the PlaybackRate whose multiplier is closest to `value`
  public static func nearest(to value: Float) -> PlaybackRate {
    let scaledValue = Int(round(value * 100))
    if let exact = PlaybackRate(rawValue: scaledValue) { return exact }
    return steps.min(by: { abs($0.rawValue - scaledValue) < abs($1.rawValue - scaledValue) }) ?? .normalTime
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
  
  /// Fast position updates for UI (slider, time displays). Uses AVPlayer's periodic time observer
  /// at 0.25s intervals for smooth updates. Only emits while playing.
  var positionPublisher: AnyPublisher<TrackPosition, Never> { get }

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
