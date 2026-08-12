//
//  DownloadTask.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier 4/11/2024
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Combine
import Foundation

// MARK: - DownloadTaskState

/// - Note: `@unchecked` rather than a checked conformance solely because of
///   `error`, which carries `any Error` — an existential the compiler cannot
///   prove `Sendable`. Every other payload is a value type. In practice the
///   errors travelling this publisher are `NSError`/`URLError`/small toolkit
///   enums, all of which are `Sendable`; the existential is what blocks the
///   proof, not the values.
///
///   The alternative, `case error((any Error & Sendable)?)`, is the strictly
///   correct spelling but ripples to every producer of this state across the
///   toolkit and the app, so it is deliberately left as follow-up work rather
///   than bundled into this wave.
public enum DownloadTaskState: @unchecked Sendable {
  case progress(Float)
  case completed
  case error(Error?)
  case deleted
}

// MARK: - DownloadTask

/// Refines `Sendable` because download tasks genuinely cross isolation domains:
/// they are created on the manifest-parsing path, driven from URLSession
/// delegate queues and the Findaway engine's callbacks, and read on the main
/// actor by the UI for the progress bar.
///
/// This refinement is what allows `Track` — and therefore `TrackPosition` — to
/// become `Sendable` in turn, so it is the root of that chain rather than a
/// local tidy-up. It is only sound because all four conformers
/// (`LCPDownloadTask`, `OpenAccessDownloadTask`, `OverdriveDownloadTask`,
/// `FindawayDownloadTask`) have had every stored property made immutable or
/// lock-guarded first; each carries a by-construction justification on its
/// declaration. A new conformer must do the same before it compiles.
public protocol DownloadTask: AnyObject, Sendable {
  var statePublisher: PassthroughSubject<DownloadTaskState, Never> { get }
  var downloadProgress: Float { get set }
  var key: String { get }
  var needsRetry: Bool { get }

  func fetch()
  func delete()
  func cancel()
  func assetFileStatus() -> AssetResult
}

extension DownloadTask {
  func cancel() {}
}
