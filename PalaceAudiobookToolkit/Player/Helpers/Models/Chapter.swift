//
//  Chapter.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

/// A titled span of an audiobook.
///
/// `Sendable` follows from `TrackPosition` being `Sendable`; the remaining
/// stored properties are a `String`, an optional `Double` and an optional
/// `TrackPosition`.
public struct Chapter: Identifiable, Equatable, Sendable {
  public var id: String = UUID().uuidString

  public var title: String
  public var position: TrackPosition
  public var duration: Double?
  public var endPosition: TrackPosition?

  mutating func calculateEndPosition(using _: Tracks) {
    guard let duration = duration else {
      endPosition = nil
      return
    }
    endPosition = position + duration
  }
}
