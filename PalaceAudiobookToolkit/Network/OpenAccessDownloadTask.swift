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
      !isForbidden
    case .saved:
      false
    }
  }

  let urlMediaType: TrackMediaType
  let alternateLinks: [(TrackMediaType, URL)]?
  let feedbooksProfile: String?
  var token: String?
  /// Host from the manifest's self link. When set, the bearer token is only
  /// sent to chapter URLs whose host matches, preventing credential leakage
  /// to unrelated domains.
  var tokenScopeHost: String?
  /// The CM fulfill URL for refreshing expired bearer tokens.
  var fulfillURL: URL?
  private var hasAttemptedTokenRefresh = false

  /// Once-per-task guard for the transient-network-error retry. Re-armed on
  /// successful download completion in `didFinishDownloadingTo`. Prevents an
  /// infinite retry loop while still recovering from a single transient blip
  /// (server returns no HTTP response, idle stall, dropped TCP mid-transfer).
  /// Helpspot 17725 (audiobook reaches halfway, then "error 914").
  private var hasAttemptedNetworkRetry = false

  /// Delay before retrying after a transient network failure. Mirrors
  /// `DownloadWatchdog.Configuration.default.retryDelay` (5s) so behaviour is
  /// consistent whether the retry comes from this inline path or the
  /// (currently un-wired) watchdog path.
  static let NetworkRetryDelay: TimeInterval = 5.0

  /// Set when the server returns 403 Forbidden. Prevents infinite retry loops
  /// that effectively DDoS the content server.
  var isForbidden = false

  /// The audiobook identifier this track belongs to. Threaded through from
  /// `OpenAccessTrack` (mirroring how `OverdriveTrack` passes `audiobookID` to
  /// `OverdriveDownloadTask`) so the download can be registered with the
  /// coordinator for background-completion finalization.
  let bookID: String

  private static let DownloadTaskTimeoutValue: TimeInterval = 60
  private var downloadURL: URL
  private var urlString: String
  private var session: URLSession?
  private var downloadTask: URLSessionDownloadTask?

  /// Strong reference to this task's session delegate. F2: the coordinator-owned
  /// session's delegate is the durable router, which holds the observer WEAKLY,
  /// so the task itself must retain its `DownloadTaskURLSessionDelegate` for it
  /// to stay alive and keep receiving forwarded callbacks. Released when the task
  /// deallocates (player close) — at which point the router's weak ref goes nil
  /// and the durable-completion fallback takes over.
  private var sessionDelegate: DownloadTaskURLSessionDelegate?

  /// The background-session identifier this task last created/reused, so the
  /// cancel/retry paths can evict the coordinator-owned session for it. (F2)
  private var backgroundSessionIdentifier: String?

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
    bookID: String,
    downloadURL: URL,
    urlString: String,
    urlMediaType: TrackMediaType,
    alternateLinks: [(TrackMediaType, URL)]?,
    feedbooksProfile: String?,
    token: String?
  ) {
    self.key = key
    self.bookID = bookID
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
    // Stable, launch-independent session identifier. Swift's `hashValue` is
    // per-process SipHash-seeded, so the previous `remoteURL.hashValue`
    // produced a *different* identifier on every launch (and wasn't even
    // book-scoped) — the reconnected background session on relaunch could
    // never match the persisted download record, so a track that finished
    // while the app was killed was silently discarded. Key the identifier on
    // the stable (bookID, trackKey) pair, mirroring the OverDrive F1 fix.
    // OpenAccess track keys are already book-scoped, so this is unique per track.
    let stableSessionKey = hash("\(bookID)-\(key)") ?? "\(bookID)-\(key)"
    let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "")
      .appending(".openAccessBackgroundIdentifier.\(stableSessionKey)")
    let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)

    // Set auth headers on the session configuration so iOS preserves them
    // when the system process takes over background transfers. Headers set
    // only on individual URLRequest objects are stripped by the background
    // transfer daemon, causing 403s on bearer-token audiobook downloads.
    var additionalHeaders: [String: String] = [:]
    if let profile = feedbooksProfile, !profile.contains("cantookaudio") {
      if let jwt = FeedbookDRMProcessor.getJWTToken(profile: profile, resourceUri: urlString) {
        additionalHeaders["Authorization"] = "Bearer \(jwt)"
      }
    } else if let token = token, shouldSendToken(to: remoteURL) {
      additionalHeaders["Authorization"] = "Bearer \(token)"
    }
    if !additionalHeaders.isEmpty {
      config.httpAdditionalHeaders = additionalHeaders
    }

    let delegate = DownloadTaskURLSessionDelegate(
      downloadTask: self,
      statePublisher: statePublisher,
      finalDirectory: finalURL,
      trackKey: key
    )
    // Retain the delegate strongly: the coordinator-owned session's delegate is
    // the durable router, which holds this observer weakly. (F2)
    sessionDelegate = delegate

    // Record the download with the coordinator so a background completion that
    // iOS delivers after the app is killed can be finalized to `finalURL` on
    // the next launch. Without this record, `activeDownloads` stays empty,
    // `handleBackgroundDownloadCompletion` hits its no-mapping branch, and the
    // finished temp file is dropped by the OS. Mirrors the OverDrive F1 fix.
    // (Also the mapping the F2 no-observer durable-completion fallback relies on.)
    AudiobookDownloadCoordinator.shared.registerActiveDownload(
      sessionIdentifier: backgroundIdentifier,
      bookID: bookID,
      trackKey: key,
      originalURL: remoteURL,
      localDestination: finalURL
    )

    // F2: GET-OR-CREATE the coordinator-owned background session. On a reopen
    // this REUSES the live session created by the previous task (instead of
    // spawning a duplicate with the same identifier, which iOS treats as
    // undefined behavior and which froze the progress bar), then re-registers
    // THIS task's delegate as the current observer so the live player sees
    // progress. We must NOT invalidate on reuse — that would kill an in-flight
    // background download.
    let ownedSession = AudiobookDownloadCoordinator.shared.session(forIdentifier: backgroundIdentifier) { router in
      URLSession(configuration: config, delegate: router, delegateQueue: nil)
    }
    AudiobookDownloadCoordinator.shared.registerObserver(delegate, forIdentifier: backgroundIdentifier)
    session = ownedSession
    backgroundSessionIdentifier = backgroundIdentifier

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

    // Also set headers on the request for non-background paths and
    // immediate transfers that may complete before backgrounding.
    if let profile = feedbooksProfile, !profile.contains("cantookaudio") {
      request.setValue(
        "Bearer \(FeedbookDRMProcessor.getJWTToken(profile: profile, resourceUri: urlString) ?? "")",
        forHTTPHeaderField: "Authorization"
      )
    } else if let token = token, shouldSendToken(to: remoteURL) {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    guard let session else {
      return
    }

    ATLog(.debug, "OpenAccessDownloadTask: Starting fresh download for: \(key)")
    let task = session.downloadTask(with: request.applyCustomUserAgent())
    task.resume()
  }

  /// Only send the bearer token when the target URL matches the manifest origin,
  /// or when no scope information is available (backwards compatibility).
  func shouldSendToken(to url: URL) -> Bool {
    guard let scopeHost = tokenScopeHost else { return true }
    return url.host == scopeHost
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
    // F2: the session is coordinator-owned. Explicit user cancel is the one case
    // where tearing it down is correct — evict it from the registry so a later
    // re-fetch creates a fresh session rather than reusing an invalidated one.
    if let identifier = backgroundSessionIdentifier {
      AudiobookDownloadCoordinator.shared.discardOwnedSession(forIdentifier: identifier)
    }
    session = nil
    sessionDelegate = nil

    downloadProgress = 0.0
    statePublisher.send(.error(nil))
    ATLog(.debug, "Download task cancelled for key: \(key)")
  }

  /// Attempts to refresh the bearer token from the stored CM fulfill URL and retry the download.
  /// Returns `true` if a refresh attempt was initiated, `false` if refresh is not possible.
  func attemptTokenRefreshAndRetry() -> Bool {
    guard let fulfillURL, !hasAttemptedTokenRefresh else {
      return false
    }

    hasAttemptedTokenRefresh = true
    ATLog(.info, "OpenAccessDownloadTask: Attempting bearer token refresh for: \(key)")

    // F2: evict the coordinator-owned session before re-fetching so the retry
    // creates a fresh session (a new bearer token means new headers on the
    // session config) instead of reusing the now-invalidated one.
    if let identifier = backgroundSessionIdentifier {
      AudiobookDownloadCoordinator.shared.discardOwnedSession(forIdentifier: identifier)
    }
    session = nil
    sessionDelegate = nil
    downloadTask = nil

    var request = URLRequest(url: fulfillURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let authToken = PalaceAuthTokenProvider.currentToken {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }

      guard let data, error == nil,
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = dictionary?["access_token"] as? String
      else {
        ATLog(.error, "OpenAccessDownloadTask: Token refresh failed for: \(self.key)")
        self.downloadProgress = 0.0
        let authError = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.authenticationRequired.rawValue,
          userInfo: [NSLocalizedDescriptionKey: "Authentication required - please sign in to your library account"]
        )
        self.statePublisher.send(.error(authError))
        return
      }

      ATLog(.info, "OpenAccessDownloadTask: Token refreshed successfully for: \(self.key)")
      self.token = accessToken
      self.hasAttemptedTokenRefresh = false
      self.fetch()
    }
    task.resume()
    return true
  }

  /// Attempts a single retry after a transient network error
  /// (server returned no HTTP response, idle stall mid-transfer, dropped
  /// connection). Returns `true` if a retry was scheduled, `false` if the
  /// retry budget for this task instance is already exhausted.
  ///
  /// HelpSpot 17725: audiobook chunk downloads were stalling mid-transfer
  /// (e.g. "reached about the halfway point before it seemed to stall...
  /// error 914"). The pre-fix behaviour surfaced a terminal `connectionLost`
  /// error to the publisher on the first transient blip, so the rest of the
  /// audiobook was lost even though the next request would have succeeded.
  ///
  /// The retry is once per task instance (re-armed on successful completion
  /// via `didFinishDownloadingTo`) and waits `NetworkRetryDelay` seconds
  /// before re-fetching, giving the network a chance to recover and avoiding
  /// hammering an origin that is genuinely down.
  ///
  /// Note: this is intentionally narrower than the full `DownloadWatchdog`
  /// retry budget (3 attempts with backoff). Keeping it bounded to one
  /// inline retry preserves "fail fast for the user" behaviour for genuine
  /// outages while recovering the dominant case (single transient blip
  /// during a long chunk download).
  func attemptNetworkRetryAfterTransientError() -> Bool {
    guard !hasAttemptedNetworkRetry else { return false }
    hasAttemptedNetworkRetry = true

    ATLog(.info, "OpenAccessDownloadTask: Scheduling network-retry in \(Self.NetworkRetryDelay)s for: \(key)")

    // F2: evict the coordinator-owned session before the delayed re-fetch so
    // the retry builds a fresh session rather than reusing an invalidated one.
    if let identifier = backgroundSessionIdentifier {
      AudiobookDownloadCoordinator.shared.discardOwnedSession(forIdentifier: identifier)
    }
    session = nil
    sessionDelegate = nil
    downloadTask = nil

    DispatchQueue.global().asyncAfter(deadline: .now() + Self.NetworkRetryDelay) { [weak self] in
      guard let self else { return }
      ATLog(.info, "OpenAccessDownloadTask: Retrying download after transient network error: \(self.key)")
      self.fetch()
    }
    return true
  }

  /// Re-arms the once-per-task network-retry guard. Called by the URLSession
  /// delegate on successful download completion so a future re-download
  /// (after delete + re-borrow, or app relaunch + retry) starts with a fresh
  /// single-retry budget. Internal-by-default; tests bypass through
  /// `@testable import` and call this to reset state between assertions.
  func resetNetworkRetryBudget() {
    hasAttemptedNetworkRetry = false
  }

  /// Test seam — read-only view of the once-per-task retry guard. Used by
  /// unit tests to assert state without poking private storage.
  var hasUsedNetworkRetry: Bool {
    hasAttemptedNetworkRetry
  }

  /// Test seam — installs `delegate` as this task's strongly-held session
  /// delegate, reproducing the exact ownership `downloadAsset` sets up
  /// (`sessionDelegate = delegate`). Lets the retain-cycle test assert that
  /// task⇄delegate is NOT a cycle: with the delegate's back-reference weak,
  /// dropping external strong refs must dealloc both. If the back-reference
  /// regressed to strong, neither would dealloc and the test would fail.
  func installSessionDelegateForTesting(_ delegate: DownloadTaskURLSessionDelegate) {
    sessionDelegate = delegate
  }
}

// MARK: - DownloadTaskURLSessionDelegate

final class DownloadTaskURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate, DownloadTaskObserver {
  /// WEAK back-reference to the owning download task. The task retains THIS
  /// delegate strongly (`sessionDelegate`) and the durable router retains the
  /// delegate only weakly as its current observer — so if this were a strong
  /// `let`, task⇄delegate would form a self-retaining cycle that never breaks on
  /// player close (nil'd only on cancel/retry). That cycle would keep the
  /// delegate alive, so the router's weak `currentObserver` would never nil and
  /// the F2 no-observer durable-completion fallback would be unreachable via the
  /// close path. Weak here breaks the cycle: on player close the audiobook graph
  /// releases the task → this delegate deallocs → `router.currentObserver` nils →
  /// a completion delivered while closed flows through Refinement 1. While a
  /// download is genuinely active the audiobook graph keeps the task alive, so
  /// this reference is non-nil for every callback that needs it.
  private weak var downloadTask: DownloadTask?
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
      ATLog(.error, "Response could not be cast to HTTPURLResponse: \(self.downloadTask?.key ?? self.trackKey)")
      statePublisher.send(.error(nil))
      return
    }

    if httpResponse.statusCode == 200 {
      verifyDownloadAndMove(from: location, to: finalURL) { success in
        if success {
          ATLog(.debug, "File successfully downloaded and moved to: \(self.finalURL)")

          // Re-arm the network-retry guard so a future re-download (e.g. user
          // deletes and re-borrows) gets a fresh single-retry budget.
          if let oaTask = self.downloadTask as? OpenAccessDownloadTask {
            oaTask.resetNetworkRetryBudget()
          }

          // Clear any saved resume data since download completed successfully
          DownloadPersistenceStore.shared.removeResumeData(forTrackKey: self.trackKey)

          if FileManager.default.fileExists(atPath: location.path) {
            do {
              try FileManager.default.removeItem(at: location)
            } catch {
              ATLog(.error, "Could not remove original downloaded file at \(location.absoluteString) Error: \(error)")
            }
          }
          self.downloadTask?.downloadProgress = 1.0
          self.statePublisher.send(.completed)
          if let task = self.downloadTask {
            NotificationCenter.default.post(name: OpenAccessTaskCompleteNotification, object: task)
          }
        } else {
          self.downloadTask?.downloadProgress = 0.0
          self.statePublisher.send(.error(nil))
        }
      }
    } else {
      ATLog(.error, "Download Task failed with server response: \n\(httpResponse.description)")
      self.downloadTask?.downloadProgress = 0.0

      if httpResponse.statusCode == 401,
         let oaTask = self.downloadTask as? OpenAccessDownloadTask,
         oaTask.attemptTokenRefreshAndRetry() {
        ATLog(.info, "DownloadTaskDelegate: 401 received, token refresh initiated for: \(self.downloadTask?.key ?? self.trackKey)")
        return
      }

      // Mark 403 Forbidden so the retry loop stops. Retrying 403 is pointless
      // (the server knows who we are but won't serve the content) and creates
      // a DDoS pattern against the content server.
      if httpResponse.statusCode == 403,
         let oaTask = self.downloadTask as? OpenAccessDownloadTask {
        ATLog(.error, "DownloadTaskDelegate: 403 Forbidden for: \(self.downloadTask?.key ?? self.trackKey) — will not retry")
        oaTask.isForbidden = true

        // Publish a typed error with HTTP status + URL context so the player
        // surfaces a specific message ("Title Unavailable") and so Palace can
        // record a Crashlytics non-fatal with full context. Generic
        // .error(nil) hid the cause and surfaced as "A Problem Has Occurred"
        // — the patron got a useless message and Crashlytics got nothing.
        let forbiddenError = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.contentForbidden.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey: OpenAccessPlayerError.contentForbidden.errorDescription(),
            "httpStatusCode": httpResponse.statusCode,
            "trackKey": self.trackKey,
            "url": httpResponse.url?.absoluteString ?? ""
          ]
        )
        statePublisher.send(.error(forbiddenError))
        return
      }

      if httpResponse.statusCode == 401 {
        let authError = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.authenticationRequired.rawValue,
          userInfo: [NSLocalizedDescriptionKey: "Authentication required - please sign in to your library account"]
        )
        statePublisher.send(.error(authError))
      } else {
        // Other 4xx/5xx: still publish a typed error so downstream sees the
        // status code and URL rather than a nil error.
        let httpError = NSError(
          domain: OpenAccessPlayerErrorDomain,
          code: OpenAccessPlayerError.unknown.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey: "Server returned HTTP \(httpResponse.statusCode)",
            "httpStatusCode": httpResponse.statusCode,
            "trackKey": self.trackKey,
            "url": httpResponse.url?.absoluteString ?? ""
          ]
        )
        statePublisher.send(.error(httpError))
      }
    }
  }

  func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    ATLog(.debug, "urlSession:task:didCompleteWithError: curl representation \(task.originalRequest?.curlString ?? "")")
    guard let error = error else {
      ATLog(.debug, "urlSession:task:didCompleteWithError: no error.")
      return
    }

    ATLog(.error, "No file URL or response from download task: \(self.downloadTask?.key ?? self.trackKey).", error: error)

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
           NSURLErrorNetworkConnectionLost,
           NSURLErrorBadServerResponse,
           NSURLErrorCannotConnectToHost,
           NSURLErrorDNSLookupFailed:
        // HelpSpot 17725: try a single bounded retry before publishing the
        // terminal connectionLost error. Recovers the dominant case (one
        // transient blip mid-chunk-download) without hammering an origin
        // that is genuinely down. Cap is per-task-instance, re-armed on
        // successful completion in `didFinishDownloadingTo`.
        if let oaTask = self.downloadTask as? OpenAccessDownloadTask,
           oaTask.attemptNetworkRetryAfterTransientError() {
          ATLog(.info, "DownloadTaskDelegate: transient network error (\(code)) for \(self.downloadTask?.key ?? self.trackKey) — retry scheduled, suppressing terminal error")
          return
        }
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

      // If the owning task has been released (player closed mid-download), skip
      // the progress update — there is no live player to show it, and the
      // reopened player re-derives progress from file state. The download itself
      // continues on the coordinator-owned session regardless.
      guard let downloadTask = self.downloadTask else { return }

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
