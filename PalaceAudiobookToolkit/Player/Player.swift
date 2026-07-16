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
  case tripleTime = 300

  // Intermediate 0.05× steps (PP-4518: rail extended to 0.50× … 3.00×)
  case p050 = 50
  case p055 = 55
  case p060 = 60
  case p065 = 65
  case p070 = 70
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
  case p205 = 205
  case p210 = 210
  case p215 = 215
  case p220 = 220
  case p225 = 225
  case p230 = 230
  case p235 = 235
  case p240 = 240
  case p245 = 245
  case p250 = 250
  case p255 = 255
  case p260 = 260
  case p265 = 265
  case p270 = 270
  case p275 = 275
  case p280 = 280
  case p285 = 285
  case p290 = 290
  case p295 = 295

  public static func convert(rate: PlaybackRate) -> Float {
    Float(rate.rawValue) * 0.01
  }

  /// Preset rates shown as quick-select chips in the speed picker UI.
  /// PP-4518 product direction: even 0.5× steps across the full rail —
  /// [0.5×, 1.0×, 1.5×, 2.0×, 2.5×, 3.0×]. This supersedes the earlier
  /// PP-4358/PP-4233 ladder. 0.75× and 1.25× are intentionally NOT chips:
  ///   - Android parity (ThePalaceProject/android-audiobook PlayerPlaybackRate.kt
  ///     ships 0.5/1.0/1.25/1.5/2.0/2.5/3.0 and likewise drops 0.75×), so
  ///     omitting 0.75× is Android-aligned;
  ///   - we deliberately omit Android's 1.25× in favor of an even 0.5 ladder.
  /// Both `.threeQuartersTime` (raw 75) and `.oneAndAQuarterTime` (raw 125)
  /// remain valid enum cases — historic UserDefaults values still decode and
  /// both stay reachable on the 0.05-step slider for accessibility slow-down.
  public static let presets: [PlaybackRate] = [
    .p050, .normalTime, .oneAndAHalfTime, .doubleTime, .p250, .tripleTime
  ]

  /// All available steps in ascending order (0.50× → 3.0×)
  public static let steps: [PlaybackRate] = PlaybackRate.allCases.sorted { $0.rawValue < $1.rawValue }

  /// Returns the PlaybackRate whose multiplier is closest to `value`
  public static func nearest(to value: Float) -> PlaybackRate {
    let scaledValue = Int(round(value * 100))
    if let exact = PlaybackRate(rawValue: scaledValue) { return exact }
    return steps.min(by: { abs($0.rawValue - scaledValue) < abs($1.rawValue - scaledValue) }) ?? .normalTime
  }
}

public extension PlaybackRate {
  /// The short multiplier label shown on the speed chip, e.g. "1.0×",
  /// "1.5×", "1.25×". Mirrors the toolkit player's own speed-chip formatting
  /// (`AudiobookPlayerView.playbackRateText` / `SpeedSliderSheet.speedLabel`).
  /// Exposed so an in-app custom player can label its speed control identically.
  var displayLabel: String {
    if self == .normalTime { return "1.0×" }
    return HumanReadablePlaybackRate.formatMultiplier(PlaybackRate.convert(rate: self))
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
