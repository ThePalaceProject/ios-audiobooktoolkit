import AVFoundation
import Combine

let OverdriveTaskCompleteNotification = NSNotification.Name(rawValue: "OverdriveDownloadTaskCompleteNotification")

// MARK: - OverdriveDownloadTask

final class OverdriveDownloadTask: DownloadTask {
  var statePublisher = PassthroughSubject<DownloadTaskState, Never>()

  var needsRetry: Bool {
    switch assetFileStatus() {
    case .missing(_), .unknown:
      true
    case .saved:
      false
    }
  }

  private static let DownloadTaskTimeoutValue = 60.0

  private var urlSession: URLSession?

  var downloadProgress: Float = 0 {
    didSet {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          return
        }
        statePublisher.send(.progress(downloadProgress))
      }
    }
  }

  let key: String
  let url: URL
  let urlMediaType: TrackMediaType
  let bookID: String

  init(key: String, url: URL, mediaType: TrackMediaType, bookID: String) {
    self.key = key
    self.url = url
    urlMediaType = mediaType
    self.bookID = bookID
  }

  func fetch() {
    switch assetFileStatus() {
    case .saved:
      downloadProgress = 1.0
      statePublisher.send(.completed)
    case let .missing(missingAssetURLs):
      switch urlMediaType {
      case .audioMP3:
        missingAssetURLs.forEach {
          self.downloadAsset(fromRemoteURL: self.url, toLocalDirectory: $0)
        }
      default:
        statePublisher.send(.error(nil))
      }
    case .unknown:
      statePublisher.send(.error(nil))
    }
  }

  func delete() {
    switch assetFileStatus() {
    case let .saved(urls):
      do {
        try urls.forEach {
          try FileManager.default.removeItem(at: $0)
          self.statePublisher.send(.deleted)
        }
      } catch {
        ATLog(.error, "FileManager removeItem error:\n\(error)")
      }
    case .missing:
      ATLog(.debug, "No file located at directory to delete.")
    case .unknown:
      ATLog(.error, "Invalid file directory from command")
    }
  }

  func assetFileStatus() -> AssetResult {
    guard let localAssetURL = localDirectory() else {
      return AssetResult.unknown
    }
    if FileManager.default.fileExists(atPath: localAssetURL.path) {
      return AssetResult.saved([localAssetURL])
    } else {
      return AssetResult.missing([localAssetURL])
    }
  }

  func localDirectory() -> URL? {
    let fileManager = FileManager.default
    let cacheDirectories = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
    guard let cacheDirectory = cacheDirectories.first else {
      ATLog(.error, "Could not find caches directory.")
      return nil
    }

    guard let filename = hash("\(bookID)-\(url)") else {
      ATLog(.error, "Could not create a valid hash from download task ID.")
      return nil
    }
    return cacheDirectory.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("mp3")
  }

  private func downloadAsset(fromRemoteURL remoteURL: URL, toLocalDirectory finalURL: URL) {
    let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "")
      .appending(".overdriveBackgroundIdentifier.\(bookID)-\(remoteURL.hashValue)")
    let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
    let delegate = DownloadTaskURLSessionDelegate(
      downloadTask: self,
      statePublisher: statePublisher,
      finalDirectory: finalURL
    )

    urlSession = URLSession(
      configuration: config,
      delegate: delegate,
      delegateQueue: nil
    )

    var request = URLRequest(
      url: remoteURL,
      cachePolicy: .reloadIgnoringLocalCacheData, // Ensure we ignore any cached data
      timeoutInterval: OverdriveDownloadTask.DownloadTaskTimeoutValue
    )

    guard let urlSession = urlSession else {
      return
    }

    let task = urlSession.downloadTask(with: request.applyCustomUserAgent())
    task.resume()
  }

  private func hash(_ key: String) -> String? {
    guard let hash = key.sha256?.hexString else {
      return nil
    }
    return hash
  }

  func cancel() {
    urlSession?.invalidateAndCancel()
    urlSession = nil

    downloadProgress = 0.0
    statePublisher.send(.error(nil))
    ATLog(.debug, "Download task cancelled for key: \(key)")
  }
}
