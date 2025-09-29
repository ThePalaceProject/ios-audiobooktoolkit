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

class DownloadTaskMock: DownloadTask {
  var statePublisher: PassthroughSubject<DownloadTaskState, Never> = PassthroughSubject()

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

  var downloadProgress: Float

  let key: String
  var needsRetry: Bool = false

  var fetchClosure: TaskCallback?
  public init(progress: Float, key: String, fetchClosure: TaskCallback?) {
    downloadProgress = progress
    self.fetchClosure = fetchClosure
    self.key = key
  }
}

extension DownloadTaskMock {
  func assetFileStatus() -> AssetResult {
    .unknown
  }
}
