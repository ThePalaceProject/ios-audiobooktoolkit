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

  /// Preset rates shown as quick-select chips in the speed picker UI.
  /// PP-4358 locks this to [0.75×, 1.0×, 1.2×, 1.5×, 2.0×]. The third
  /// preset is `.p120` (1.20×), not `.oneAndAQuarterTime` (1.25×) — the
  /// PP-4233 design review picked 1.2× over 1.25×. `.oneAndAQuarterTime`
  /// remains a valid enum case so historic UserDefaults values (raw 125)
  /// still decode for users who selected 1.25× before this change.
  public static let presets: [PlaybackRate] = [
    .threeQuartersTime, .normalTime, .p120, .oneAndAHalfTime, .doubleTime
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

  /// Skips the playhead by `timeInterval` seconds (negative for back).
  /// Returns the resulting `TrackPosition`, or nil if no position could
  /// be determined (e.g. player not loaded, no current position).
  func skipPlayhead(_ timeInterval: TimeInterval) async -> TrackPosition?

  /// Begins playback at the given position. Throws if the underlying
  /// seek/load fails. Successful return implies AVPlayer is now playing
  /// (or has been told to play; race against AVPlayer rate is unchanged
  /// from the prior callback shape).
  func play(at position: TrackPosition) async throws

  /// Moves the playhead to fractional progress `value` (0.0..1.0) within
  /// the current chapter. Returns the resulting `TrackPosition`, or nil
  /// if no current position / chapter could be resolved.
  func move(to value: Double) async -> TrackPosition?
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
