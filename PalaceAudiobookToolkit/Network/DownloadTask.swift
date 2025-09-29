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

public enum DownloadTaskState {
  case progress(Float)
  case completed
  case error(Error?)
  case deleted
}

// MARK: - DownloadTask

public protocol DownloadTask: AnyObject {
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
