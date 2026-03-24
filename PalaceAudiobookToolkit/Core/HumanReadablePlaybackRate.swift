//
// HumanReadablePlaybackRate.swift
// NYPLAudiobookToolkit
//
// Created by Dean Silfen on 3/27/18.
// Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

class HumanReadablePlaybackRate {
  lazy var value: String = {
    if rate == .normalTime {
      return NSLocalizedString(
        "1.0× (Normal)",
        bundle: Bundle.audiobookToolkit()!,
        value: "1.0× (Normal)",
        comment: "Normal time"
      )
    }
    return Self.formatMultiplier(PlaybackRate.convert(rate: rate))
  }()

  lazy var accessibleDescription: String = {
    switch rate {
    case .threeQuartersTime:
      return NSLocalizedString(
        "Three quarters of normal speed. Slower.",
        bundle: Bundle.audiobookToolkit()!,
        value: "Three quarters of normal speed. Slower.",
        comment: ""
      )
    case .normalTime:
      return NSLocalizedString("Normal speed.", bundle: Bundle.audiobookToolkit()!, value: "Normal speed.", comment: "")
    case .doubleTime:
      return NSLocalizedString(
        "Two times normal speed. Fastest.",
        bundle: Bundle.audiobookToolkit()!,
        value: "Two times normal speed. Fastest.",
        comment: ""
      )
    default:
      let multiplier = PlaybackRate.convert(rate: rate)
      let formatted = Self.formatMultiplier(multiplier)
      if multiplier < 1.0 {
        return String(format: NSLocalizedString("%@ speed. Slower than normal.", bundle: Bundle.audiobookToolkit()!, value: "%@ speed. Slower than normal.", comment: ""), formatted)
      } else {
        return String(format: NSLocalizedString("%@ speed. Faster than normal.", bundle: Bundle.audiobookToolkit()!, value: "%@ speed. Faster than normal.", comment: ""), formatted)
      }
    }
  }()

  let rate: PlaybackRate

  init(rate: PlaybackRate) {
    self.rate = rate
  }

  /// Formats a multiplier Float as "1.25×", trimming insignificant trailing zeros.
  static func formatMultiplier(_ multiplier: Float) -> String {
    // Use up to 2 decimal places, trim trailing zeros
    let value = Double(multiplier)
    if value.truncatingRemainder(dividingBy: 1) == 0 {
      return String(format: "%.1f×", value)
    } else if (value * 10).truncatingRemainder(dividingBy: 1) == 0 {
      return String(format: "%.1f×", value)
    } else {
      return String(format: "%.2f×", value)
    }
  }
}
