import AVFoundation
import Combine

let OpenAccessTaskCompleteNotification = NSNotification.Name(rawValue: "OpenAccessDownloadTaskCompleteNotification")

// MARK: - AssetResult

public enum AssetResult {
  /// The file exists at the given URL.
  case saved([URL])
  /// The file is missing at the given URL.
  case missing([URL])
  /// Could not create a valid URL to check.
  case unknown
}

// MARK: - OpenAccessDownloadTask

final class OpenAccessDownloadTask: DownloadTask {
  var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
  var key: String
  var needsRetry: Bool {
    switch assetFileStatus() {
    case .missing, .unknown:
      true
    case .saved:
      false
    }
  }

  let urlMediaType: TrackMediaType
  let alternateLinks: [(TrackMediaType, URL)]?
  let feedbooksProfile: String?
  let token: String?

  private static let DownloadTaskTimeoutValue: TimeInterval = 60
  private var downloadURL: URL
  private var urlString: String
  private var session: URLSession?
  private var downloadTask: URLSessionDownloadTask?

  /// Progress should be set to 1 if the file already exists.
  /// Lazily initialized based on actual file status to avoid showing 0% for downloaded files.
  private var _downloadProgress: Float?
  var downloadProgress: Float {
    get {
      if _downloadProgress == nil {
        // Initialize based on actual file status
        switch assetFileStatus() {
        case .saved:
          _downloadProgress = 1.0
        case .missing, .unknown:
          _downloadProgress = 0.0
        }
      }
      return _downloadProgress ?? 0.0
    }
    set {
      let oldValue = _downloadProgress
      _downloadProgress = newValue
      // Only publish if value changed to avoid duplicate events
      if oldValue != newValue {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.statePublisher.send(.progress(newValue))
        }
      }
    }
  }

  init(
    key: String,
    downloadURL: URL,
    urlString: String,
    urlMediaType: TrackMediaType,
    alternateLinks: [(TrackMediaType, URL)]?,
    feedbooksProfile: String?,
    token: String?
  ) {
    self.key = key
    self.downloadURL = downloadURL
    self.urlString = urlString
    self.urlMediaType = urlMediaType
    self.alternateLinks = alternateLinks
    self.feedbooksProfile = feedbooksProfile
    self.token = token
  }

  /// If the asset is already downloaded and verified, return immediately and
  /// update state to the delegates. Otherwise, attempt to download the file
  /// referenced in the spine element.
  func fetch() {
    switch assetFileStatus() {
    case .saved:
      downloadProgress = 1.0
      statePublisher.send(.completed)
    case let .missing(missingAssetURLs):
      switch urlMediaType {
      case .rbDigital:
        missingAssetURLs.forEach {
          self.downloadAssetForRBDigital(toLocalDirectory: $0)
        }
      default:
        missingAssetURLs.forEach {
          self.downloadAsset(fromRemoteURL: self.downloadURL, toLocalDirectory: $0)
        }
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

  /// Directory of the downloaded file.
  /// Uses Application Support instead of Caches to prevent iOS from purging files.
  private func localDirectory() -> URL? {
    let fileManager = FileManager.default
    
    // Use Application Support directory instead of Caches for persistence
    guard let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      ATLog(.error, "Could not find Application Support directory.")
      return nil
    }
    
    // Create audiobooks subdirectory
    let audiobooksDirectory = appSupportDirectory.appendingPathComponent("Audiobooks/Downloads", isDirectory: true)
    
    // Create directory if it doesn't exist
    if !fileManager.fileExists(atPath: audiobooksDirectory.path) {
      do {
        try fileManager.createDirectory(at: audiobooksDirectory, withIntermediateDirectories: true, attributes: nil)
        
        // Exclude from iCloud backup (required by Apple for downloaded content)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = audiobooksDirectory
        try mutableURL.setResourceValues(resourceValues)
      } catch {
        ATLog(.error, "Could not create audiobooks directory: \(error.localizedDescription)")
        return nil
      }
    }
    
    guard let filename = hash(key) else {
      ATLog(.error, "Could not create a valid hash from download task ID.")
      return nil
    }
    return audiobooksDirectory.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("mp3")
  }
  
  /// Migrates files from old Caches location to new Application Support location.
  /// Call this on app launch to migrate existing downloads.
  public static func migrateFromCachesIfNeeded() {
    let fileManager = FileManager.default
    
    guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
          let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return
    }
    
    let newDir = appSupportDir.appendingPathComponent("Audiobooks/Downloads", isDirectory: true)
    
    // Create new directory if needed
    if !fileManager.fileExists(atPath: newDir.path) {
      try? fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)
    }
    
    // Find and migrate .mp3 files from caches
    do {
      let cacheContents = try fileManager.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: nil)
      let mp3Files = cacheContents.filter { $0.pathExtension == "mp3" }
      
      for oldURL in mp3Files {
        let newURL = newDir.appendingPathComponent(oldURL.lastPathComponent)
        if !fileManager.fileExists(atPath: newURL.path) {
          do {
            try fileManager.moveItem(at: oldURL, to: newURL)
            ATLog(.info, "Migrated audiobook file from Caches to Application Support: \(oldURL.lastPathComponent)")
          } catch {
            ATLog(.warn, "Failed to migrate audiobook file: \(error.localizedDescription)")
          }
        }
      }
    } catch {
      ATLog(.debug, "No files to migrate from Caches: \(error.localizedDescription)")
    }
  }

  /// RBDigital media types first download an intermediate document, which points
  /// to the url of the actual asset to download.
  private func downloadAssetForRBDigital(toLocalDirectory localURL: URL) {
    let task = URLSession.shared.dataTask(with: downloadURL) { data, response, error in
      guard let data = data,
            let response = response,
            error == nil
      else {
        ATLog(.error, "Network request failed for RBDigital partial file. Error: \(error!.localizedDescription)")
        return
      }

      if (response as? HTTPURLResponse)?.statusCode == 200 {
        do {
          if let responseBody = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
             let typeString = responseBody["type"] as? String,
             let mediaType = TrackMediaType(rawValue: typeString),
             let urlString = responseBody["url"] as? String,
             let assetUrl = URL(string: urlString)
          {
            switch mediaType {
            case .audioMPEG:
              fallthrough
            case .audioMP4:
              self.downloadAsset(fromRemoteURL: assetUrl, toLocalDirectory: localURL)
            default:
              ATLog(.error, "Wrong media type for download task.")
            }
          } else {
            ATLog(.error, "Invalid or missing property in JSON response to download task.")
          }
        } catch {
          ATLog(.error, "Error deserializing JSON in download task.")
        }
      } else {
        ATLog(.error, "Failed with server response: \n\(response.description)")
      }
    }
    task.resume()
  }

  private func downloadAsset(fromRemoteURL remoteURL: URL, toLocalDirectory finalURL: URL) {
    let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "")
      .appending(".openAccessBackgroundIdentifier.\(remoteURL.hashValue)")
    let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
    let delegate = DownloadTaskURLSessionDelegate(
      downloadTask: self,
      statePublisher: statePublisher,
      finalDirectory: finalURL,
      trackKey: key
    )

    session = URLSession(
      configuration: config,
      delegate: delegate,
      delegateQueue: nil
    )
    
    // Check for resume data from a previous interrupted download
    if let resumeData = DownloadPersistenceStore.shared.getResumeData(forTrackKey: key) {
      ATLog(.info, "OpenAccessDownloadTask: Resuming download from saved state for: \(key)")
      guard let session else { return }
      let task = session.downloadTask(withResumeData: resumeData)
      task.resume()
      return
    }
    
    // No resume data - start fresh download
    var request = URLRequest(
      url: remoteURL,
      cachePolicy: .useProtocolCachePolicy,
      timeoutInterval: OpenAccessDownloadTask.DownloadTaskTimeoutValue
    )

    // Feedbooks DRM
    // CantookAudio does not support Authorization fields, so exclude them for that provider
    if let profile = feedbooksProfile, !profile.contains("cantookaudio") {
      request.setValue(
        "Bearer \(FeedbookDRMProcessor.getJWTToken(profile: profile, resourceUri: urlString) ?? "")",
        forHTTPHeaderField: "Authorization"
      )
    } else if let token = token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    guard let session else {
      return
    }

    ATLog(.debug, "OpenAccessDownloadTask: Starting fresh download for: \(key)")
    let task = session.downloadTask(with: request.applyCustomUserAgent())
    task.resume()
  }

  private func hash(_ key: String) -> String? {
    guard let hash = key.sha256?.hexString else {
      return nil
    }
    return hash
  }

  func cancel() {
    // Try to save resume data before cancelling
    if let urlSessionTask = session?.getAllTasks(completionHandler: { _ in }) as? [URLSessionDownloadTask],
       let downloadTask = urlSessionTask.first {
      downloadTask.cancel(byProducingResumeData: { [weak self] resumeData in
        guard let self = self, let data = resumeData else { return }
        DownloadPersistenceStore.shared.saveResumeData(data, forTrackKey: self.key)
        ATLog(.info, "OpenAccessDownloadTask: Saved resume data on cancel for: \(self.key)")
      })
    } else {
      // Fallback: just cancel without resume data
      downloadTask?.cancel()
    }
    
    downloadTask = nil
    session?.invalidateAndCancel()
    session = nil

    downloadProgress = 0.0
    statePublisher.send(.error(nil))
    ATLog(.debug, "Download task cancelled for key: \(key)")
  }
}

// MARK: - DownloadTaskURLSessionDelegate

final class DownloadTaskURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {
  private let downloadTask: DownloadTask
  private var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
  private let finalURL: URL
  private let trackKey: String

  /// Each Spine Element's Download Task has a URLSession delegate.
  /// If the player ever evolves to support concurrent requests, there
  /// should just be one delegate objects that keeps track of them all.
  /// This is only for the actual audio file download.
  ///
  /// - Parameters:
  ///   - downloadTask: The corresponding download task for the URLSession.
  ///   - statePublisher: Publisher to forward download state changes
  ///   - finalDirectory: Final directory to move the asset to
  ///   - trackKey: Unique key for the track (used for resume data storage)
  required init(
    downloadTask: DownloadTask,
    statePublisher: PassthroughSubject<DownloadTaskState, Never>,
    finalDirectory: URL,
    trackKey: String
  ) {
    self.downloadTask = downloadTask
    self.statePublisher = statePublisher
    self.finalURL = finalDirectory
    self.trackKey = trackKey
  }

  func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
      ATLog(.error, "Response could not be cast to HTTPURLResponse: \(self.downloadTask.key)")
      statePublisher.send(.error(nil))
      return
    }

    if httpResponse.statusCode == 200 {
      verifyDownloadAndMove(from: location, to: finalURL) { success in
        if success {
          ATLog(.debug, "File successfully downloaded and moved to: \(self.finalURL)")
          
          // Clear any saved resume data since download completed successfully
          DownloadPersistenceStore.shared.removeResumeData(forTrackKey: self.trackKey)
          
          if FileManager.default.fileExists(atPath: location.path) {
            do {
              try FileManager.default.removeItem(at: location)
            } catch {
              ATLog(.error, "Could not remove original downloaded file at \(location.absoluteString) Error: \(error)")
            }
          }
          self.downloadTask.downloadProgress = 1.0
          self.statePublisher.send(.completed)
          NotificationCenter.default.post(name: OpenAccessTaskCompleteNotification, object: self.downloadTask)
        } else {
          self.downloadTask.downloadProgress = 0.0
          self.statePublisher.send(.error(nil))
        }
      }
    } else {
      ATLog(.error, "Download Task failed with server response: \n\(httpResponse.description)")
      self.downloadTask.downloadProgress = 0.0
      
      // Create specific error for 401 (authentication required)
      if httpResponse.statusCode == 401 {
        let authError = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.authenticationRequired.rawValue,
          userInfo: [NSLocalizedDescriptionKey: "Authentication required - please sign in to your library account"]
        )
        statePublisher.send(.error(authError))
      } else {
        statePublisher.send(.error(nil))
      }
    }
  }

  func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    ATLog(.debug, "urlSession:task:didCompleteWithError: curl representation \(task.originalRequest?.curlString ?? "")")
    guard let error = error else {
      ATLog(.debug, "urlSession:task:didCompleteWithError: no error.")
      return
    }

    ATLog(.error, "No file URL or response from download task: \(downloadTask.key).", error: error)
    
    // Try to save resume data for later recovery
    let nsError = error as NSError
    if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
      DownloadPersistenceStore.shared.saveResumeData(resumeData, forTrackKey: trackKey)
      ATLog(.info, "Saved resume data on error for track: \(trackKey) (\(resumeData.count) bytes)")
    }

    if let code = nsError.code as Int? {
      switch code {
      case NSURLErrorNotConnectedToInternet,
           NSURLErrorTimedOut,
           NSURLErrorNetworkConnectionLost:
        let networkLossError = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.connectionLost.rawValue,
          userInfo: nil
        )
        statePublisher.send(.error(networkLossError))
        return
      case NSURLErrorCancelled:
        // Download was cancelled - resume data already saved above if available
        ATLog(.debug, "Download cancelled for track: \(trackKey)")
        statePublisher.send(.error(error))
        return
      default:
        break
      }
    }

    statePublisher.send(.error(error))
  }

  func urlSession(
    _: URLSession,
    downloadTask _: URLSessionDownloadTask,
    didWriteData _: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }

      if totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown || totalBytesExpectedToWrite == 0 {
        downloadTask.downloadProgress = 0.0
      } else if totalBytesWritten >= totalBytesExpectedToWrite {
        downloadTask.downloadProgress = 1.0
      } else if totalBytesWritten <= 0 {
        downloadTask.downloadProgress = 0.0
      } else {
        downloadTask.downloadProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
      }
    }
  }

  func verifyDownloadAndMove(from: URL, to: URL, completionHandler: @escaping (Bool) -> Void) {
    if MediaProcessor.fileNeedsOptimization(url: from) {
      ATLog(.debug, "Media file needs optimization: \(from.absoluteString)")
      MediaProcessor.optimizeQTFile(input: from, output: to, completionHandler: completionHandler)
    } else {
      do {
        try FileManager.default.moveItem(at: from, to: to)
        completionHandler(true)
      } catch {
        // Error code 516 is thrown when the file has already successfully
        // been downloaded and moved to the save location. Download is verified.
        if (error as NSError).code == 516 {
          completionHandler(true)
          return
        }

        ATLog(.error, "FileManager removeItem error:\n\(error)")
        completionHandler(false)
      }
    }
  }
}
