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
/// local tidy-up. It is only sound because every conformer has had its stored
/// properties made immutable or lock-guarded first, each carrying a
/// by-construction justification on its declaration: `LCPDownloadTask`,
/// `OpenAccessDownloadTask`, `OverdriveDownloadTask`, `FindawayDownloadTask`,
/// and the test double `DownloadTaskMock`.
///
/// - Important: the bar is **not** "every stored property is a `let`" — it is
///   "every stored property is a `let` *whose referent is itself thread-safe*,
///   or is lock-guarded". A `let` pointing at unsynchronized mutable state
///   proves nothing. That distinction is the whole reason
///   `AudiobookNetworkService` correctly refuses this conformance: all of its
///   own properties are `let` or guarded, but three of those `let`s reference
///   types that are not.
///
/// - Important: adding a conformer does NOT force this check automatically. The
///   test target has no `SWIFT_STRICT_CONCURRENCY` setting, so a conformer
///   declared there can violate the contract silently — which
///   `DownloadTaskMock` did until it was audited. Verify new conformers by
///   hand.
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
