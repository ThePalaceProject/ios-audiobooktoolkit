//
//  DownloadTaskMock.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Dean Silfen on 3/5/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Combine
import PalaceAudiobookToolkit
import UIKit

typealias TaskCallback = (_ task: DownloadTask) -> Void

// MARK: - DownloadTaskMock

/// - Note: `DownloadTask` refines `Sendable`, so this test double has to hold
///   up its end of that contract like any production conformer. It previously
///   did not — it was a non-final class with three unguarded `var`s, and only
///   compiled because the test target has no `SWIFT_STRICT_CONCURRENCY`
///   setting of its own. A mock that quietly violates the protocol's
///   thread-safety contract is worse than useless: tests would pass against
///   arrangements the real conformers forbid.
///
///   `@unchecked Sendable` is justified by construction here exactly as it is
///   in production: `key` is a `let`, and all three mutable properties are
///   reached only under `lock`. `statePublisher` is a `let` whose referent is
///   thread-safe for the single-writer use these tests make of it.
final class DownloadTaskMock: DownloadTask, @unchecked Sendable {
  let statePublisher: PassthroughSubject<DownloadTaskState, Never> = PassthroughSubject()

  private let lock = NSLock()
  private var _downloadProgress: Float
  private var _needsRetry = false
  private var _fetchClosure: TaskCallback?

  func fetch() {
    guard let fetchClosure = fetchClosure else {
      return
    }
    // Call the closure async to prevent temporal dependencies.
    DispatchQueue.main.async { [weak self] () in
      if let strongSelf = self {
        fetchClosure(strongSelf)
      }
    }
  }

  func delete() {}

  func cancel() {}

  var downloadProgress: Float {
    get { lock.withLock { _downloadProgress } }
    set { lock.withLock { _downloadProgress = newValue } }
  }

  let key: String

  var needsRetry: Bool {
    get { lock.withLock { _needsRetry } }
    set { lock.withLock { _needsRetry = newValue } }
  }

  var fetchClosure: TaskCallback? {
    get { lock.withLock { _fetchClosure } }
    set { lock.withLock { _fetchClosure = newValue } }
  }

  public init(progress: Float, key: String, fetchClosure: TaskCallback?) {
    _downloadProgress = progress
    _fetchClosure = fetchClosure
    self.key = key
  }
}

extension DownloadTaskMock {
  func assetFileStatus() -> AssetResult {
    .unknown
  }
}
