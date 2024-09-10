import AVFoundation
import Combine

let OverdriveTaskCompleteNotification = NSNotification.Name(rawValue: "OverdriveDownloadTaskCompleteNotification")

final class OverdriveDownloadTask: DownloadTask {
    
    var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    
    var needsRetry: Bool {
        switch self.assetFileStatus() {
        case .missing(_), .unknown:
            return true
        case .saved(_):
            return false
        }
    }
    
    private static let DownloadTaskTimeoutValue = 60.0
    
    private var urlSession: URLSession?
    
    var downloadProgress: Float = 0 {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.statePublisher.send(.progress(self.downloadProgress))
            }
        }
    }
    
    let key: String
    let url: URL
    let urlMediaType: TrackMediaType
    let bookID: String // Add a book ID to differentiate between books
    
    init(key: String, url: URL, mediaType: TrackMediaType, bookID: String) {
        self.key = key
        self.url = url
        self.urlMediaType = mediaType
        self.bookID = bookID // Store the unique book ID
    }
    
    func fetch() {
        switch self.assetFileStatus() {
        case .saved(_):
            downloadProgress = 1.0
            self.statePublisher.send(.completed)
        case .missing(let missingAssetURLs):
            switch urlMediaType {
            case .audioMP3:
                missingAssetURLs.forEach {
                    self.downloadAsset(fromRemoteURL: self.url, toLocalDirectory: $0)
                }
            default:
                self.statePublisher.send(.error(nil))
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
    
    func localDirectory() -> URL? {
        let fileManager = FileManager.default
        let cacheDirectories = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let cacheDirectory = cacheDirectories.first else {
            ATLog(.error, "Could not find caches directory.")
            return nil
        }
        // Use the book ID and URL hash to ensure unique file paths
        guard let filename = hash("\(bookID)-\(url)") else {
            ATLog(.error, "Could not create a valid hash from download task ID.")
            return nil
        }
        return cacheDirectory.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("mp3")
    }
    
    private func downloadAsset(fromRemoteURL remoteURL: URL, toLocalDirectory finalURL: URL) {
        let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "").appending(".overdriveBackgroundIdentifier.\(bookID)-\(remoteURL.hashValue)")
        let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        let delegate = DownloadTaskURLSessionDelegate(downloadTask: self,
                                                      statePublisher: self.statePublisher,
                                                      finalDirectory: finalURL)
        
        urlSession = URLSession(configuration: config,
                                delegate: delegate,
                                delegateQueue: nil)
        
        var request = URLRequest(url: remoteURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData, // Ensure we ignore any cached data
                                 timeoutInterval: OverdriveDownloadTask.DownloadTaskTimeoutValue)
        
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
}
