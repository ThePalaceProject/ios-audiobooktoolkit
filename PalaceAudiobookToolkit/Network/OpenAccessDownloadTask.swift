import AVFoundation
import Combine

let OpenAccessTaskCompleteNotification = NSNotification.Name(rawValue: "OpenAccessDownloadTaskCompleteNotification")

enum AssetResult {
    /// The file exists at the given URL.
    case saved([URL])
    /// The file is missing at the given URL.
    case missing([URL])
    /// Could not create a valid URL to check.
    case unknown
}

final class OpenAccessDownloadTask: DownloadTask {
    var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    var key: String

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
    var downloadProgress: Float = 0 {
        didSet {
            self.statePublisher.send(.progress(downloadProgress))
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
        switch self.assetFileStatus() {
        case .saved(_):
            downloadProgress = 1.0
            self.statePublisher.send(.completed)
        case .missing(let missingAssetURLs):
            switch urlMediaType {
            case .rbDigital:
                missingAssetURLs.forEach {
                    self.downloadAssetForRBDigital(toLocalDirectory: $0)
                }
            default:
                missingAssetURLs.forEach {
                    self.downloadAsset(fromRemoteURL: self.downloadURL, toLocalDirectory:  $0)
                }
            }
        case .unknown:
            self.statePublisher.send(.error(nil))
        }
    }

    func delete() {
        switch self.assetFileStatus() {
        case .saved(let urls):
            do {
               try urls.forEach {
                    try FileManager.default.removeItem(at: $0)
                    self.statePublisher.send(.deleted)
                }
            } catch {
                ATLog(.error, "FileManager removeItem error:\n\(error)")
            }
        case .missing(_):
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
    private func localDirectory() -> URL? {
        let fileManager = FileManager.default
        let cacheDirectories = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let cacheDirectory = cacheDirectories.first else {
            ATLog(.error, "Could not find caches directory.")
            return nil
        }
        guard let filename = hash(self.key) else {
            ATLog(.error, "Could not create a valid hash from download task ID.")
            return nil
        }
        return cacheDirectory.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("mp3")
    }

    /// RBDigital media types first download an intermediate document, which points
    /// to the url of the actual asset to download.
    private func downloadAssetForRBDigital(toLocalDirectory localURL: URL) {

        let task = URLSession.shared.dataTask(with: self.downloadURL) { (data, response, error) in

            guard let data = data,
                let response = response,
                (error == nil) else {
                ATLog(.error, "Network request failed for RBDigital partial file. Error: \(error!.localizedDescription)")
                return
            }

            if (response as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    if let responseBody = try JSONSerialization.jsonObject(with: data, options: []) as? [String:Any],
                        let typeString = responseBody["type"] as? String,
                        let mediaType = TrackMediaType(rawValue: typeString),
                        let urlString = responseBody["url"] as? String,
                        let assetUrl = URL(string: urlString) {

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

    private func downloadAsset(fromRemoteURL remoteURL: URL, toLocalDirectory finalURL: URL)
    {
        let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "").appending(".openAccessBackgroundIdentifier.\(remoteURL.hashValue)")
        let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        let delegate = DownloadTaskURLSessionDelegate(downloadTask: self,
                                                                statePublisher: self.statePublisher,
                                                                finalDirectory: finalURL)
        session = URLSession(configuration: config,
                                delegate: delegate,
                                delegateQueue: nil)
        var request = URLRequest(url: remoteURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: OpenAccessDownloadTask.DownloadTaskTimeoutValue)
        
        // Feedbooks DRM
        // CantookAudio does not support Authorization fields causing downloads to fail, this fix may need to be less exclusive
        // if future issues arise with other providers.
        if let profile = self.feedbooksProfile, !profile.contains("cantookaudio") {
            request.setValue("Bearer \(FeedbookDRMProcessor.getJWTToken(profile: profile, resourceUri: urlString) ?? "")", forHTTPHeaderField: "Authorization")
        } else if let token = self.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        guard let session else {
            return
        }
        
        let task = session.downloadTask(with: request.applyCustomUserAgent())
        task.resume()
    }

    private func hash(_ key: String) -> String? {
        guard let hash = key.sha256?.hexString else {
            return nil
        }
        return hash
    }
}

final class DownloadTaskURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {

    private let downloadTask: DownloadTask
    private var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    private let finalURL: URL

    /// Each Spine Element's Download Task has a URLSession delegate.
    /// If the player ever evolves to support concurrent requests, there
    /// should just be one delegate objects that keeps track of them all.
    /// This is only for the actual audio file download.
    ///
    /// - Parameters:
    ///   - downloadTask: The corresponding download task for the URLSession.
    ///   - delegate: The DownloadTaskDelegate, to forward download progress
    ///   - finalDirectory: Final directory to move the asset to
    required init(downloadTask: DownloadTask,
                  statePublisher: PassthroughSubject<DownloadTaskState, Never>,
                  finalDirectory: URL) {
        self.downloadTask = downloadTask
        self.statePublisher = statePublisher
        self.finalURL = finalDirectory
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
       guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
            ATLog(.error, "Response could not be cast to HTTPURLResponse: \(self.downloadTask.key)")
            self.statePublisher.send(.error(nil))
            return
        }

        if (httpResponse.statusCode == 200) {
            verifyDownloadAndMove(from: location, to: self.finalURL) { (success) in
                if success {
                    ATLog(.debug, "File successfully downloaded and moved to: \(self.finalURL)")
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
            self.statePublisher.send(.error(nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        ATLog(.debug, "urlSession:task:didCompleteWithError: curl representation \(task.originalRequest?.curlString ?? "")")
        guard let error = error else {
            ATLog(.debug, "urlSession:task:didCompleteWithError: no error.")
            return
        }

        ATLog(.error, "No file URL or response from download task: \(self.downloadTask.key).", error: error)

        if let code = (error as NSError?)?.code {
            switch code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost:
                let networkLossError = NSError(domain: OpenAccessPlayerErrorDomain, code: OpenAccessPlayerError.connectionLost.rawValue, userInfo: nil)
                self.statePublisher.send(.error(networkLossError))
                return
            default:
                break
            }
        }
    
        self.statePublisher.send(.error(error))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64)
    {
        if (totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown) ||
            totalBytesExpectedToWrite == 0 {
            self.downloadTask.downloadProgress = 0.0
        }

        if totalBytesWritten >= totalBytesExpectedToWrite {
            self.downloadTask.downloadProgress = 1.0
        } else if totalBytesWritten <= 0 {
            self.downloadTask.downloadProgress = 0.0
        } else {
            self.downloadTask.downloadProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
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
