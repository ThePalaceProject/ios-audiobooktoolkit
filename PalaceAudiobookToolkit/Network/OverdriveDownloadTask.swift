import AVFoundation
import Combine

let OverdriveTaskCompleteNotification = NSNotification.Name(rawValue: "OverdriveDownloadTaskCompleteNotification")

// MARK: - OverdriveDownloadTask

final class OverdriveDownloadTask: DownloadTask {
  var statePublisher = PassthroughSubject<DownloadTaskState, Never>()

  var needsRetry: Bool {
    switch assetFileStatus() {
    case .missing, .unknown:
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

  /// Returns the local storage URL for this track.
  /// Uses Application Support instead of Caches to prevent iOS from purging files.
  func localDirectory() -> URL? {
    let fileManager = FileManager.default
    
    // Use Application Support directory instead of Caches for persistence
    guard let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      ATLog(.error, "Could not find Application Support directory.")
      return nil
    }
    
    // Use shared Audiobooks/Downloads directory for all audiobook types
    // This ensures backward compatibility during migration (can't distinguish file types)
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
        ATLog(.error, "Could not create OverDrive audiobooks directory: \(error.localizedDescription)")
        return nil
      }
    }

    guard let filename = hash("\(bookID)-\(url)") else {
      ATLog(.error, "Could not create a valid hash from download task ID.")
      return nil
    }
    return audiobooksDirectory.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("mp3")
  }
  
  /// Migrates files from old Caches location to new Application Support location.
  /// Note: This is now handled by OpenAccessDownloadTask.migrateFromCachesIfNeeded()
  /// since both use the same shared directory. This method is kept for API compatibility.
  public static func migrateFromCachesIfNeeded() {
    // Migration is handled by OpenAccessDownloadTask.migrateFromCachesIfNeeded()
    // Both OverDrive and OpenAccess now use the shared Audiobooks/Downloads directory
    // to ensure backward compatibility (we can't distinguish file types during migration)
    ATLog(.debug, "OverdriveDownloadTask: Migration delegated to shared handler")
  }

  private func downloadAsset(fromRemoteURL remoteURL: URL, toLocalDirectory finalURL: URL) {
    let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "")
      .appending(".overdriveBackgroundIdentifier.\(bookID)-\(remoteURL.hashValue)")
    let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
    let delegate = DownloadTaskURLSessionDelegate(
      downloadTask: self,
      statePublisher: statePublisher,
      finalDirectory: finalURL,
      trackKey: key
    )

    urlSession = URLSession(
      configuration: config,
      delegate: delegate,
      delegateQueue: nil
    )
    
    // Check for resume data from a previous interrupted download
    if let resumeData = DownloadPersistenceStore.shared.getResumeData(forTrackKey: key) {
      ATLog(.info, "OverdriveDownloadTask: Resuming download from saved state for: \(key)")
      guard let urlSession = urlSession else { return }
      let task = urlSession.downloadTask(withResumeData: resumeData)
      task.resume()
      return
    }

    // No resume data - start fresh download
    var request = URLRequest(
      url: remoteURL,
      cachePolicy: .reloadIgnoringLocalCacheData, // Ensure we ignore any cached data
      timeoutInterval: OverdriveDownloadTask.DownloadTaskTimeoutValue
    )

    guard let urlSession = urlSession else {
      return
    }

    ATLog(.debug, "OverdriveDownloadTask: Starting fresh download for: \(key)")
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
    // Try to save resume data before cancelling
    urlSession?.getAllTasks { [weak self] tasks in
      guard let self = self else { return }
      if let downloadTask = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first {
        downloadTask.cancel(byProducingResumeData: { resumeData in
          if let data = resumeData {
            DownloadPersistenceStore.shared.saveResumeData(data, forTrackKey: self.key)
            ATLog(.info, "OverdriveDownloadTask: Saved resume data on cancel for: \(self.key)")
          }
        })
      }
    }
    
    urlSession?.invalidateAndCancel()
    urlSession = nil

    downloadProgress = 0.0
    statePublisher.send(.error(nil))
    ATLog(.debug, "Download task cancelled for key: \(key)")
  }
}
