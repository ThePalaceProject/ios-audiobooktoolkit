//
//  DownloadTask.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/23/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Foundation
import Combine

//TODO: Deprecate

/// Notifications about the status of the download.
@objc public protocol DownloadTaskDelegate: class {
    func downloadTaskReadyForPlayback(_ downloadTask: DownloadTask)
    func downloadTaskDidDeleteAsset(_ downloadTask: DownloadTask)
    func downloadTaskDidUpdateDownloadPercentage(_ downloadTask: DownloadTask)
    func downloadTaskFailed(_ downloadTask: DownloadTask, withError error: NSError?)
}

/// Protocol to handle hitting the network to download an audiobook.
/// Implementers of this protocol should handle the download with one source.
/// There should be multiple objects that implement DownloadTask, each working
/// with a different Network API.
/// For example, one for AudioEngine networking, one for URLSession, etc.
///
/// If a DownloadTask is attempting to download a file that is already available
/// locally, it should notify it's delegates as if it were a successful download.
@objc public protocol DownloadTask: class {
    
    /// Ask the task to fetch the file and notify it's delegate
    /// when playback is ready. If this file is stored locally
    /// already, it should simply call the delegate immediately.
    ///
    /// Implementations of `fetch` should be idempotent, if a
    /// task is already requesting data it should not fire
    /// a subsequent request.
    func fetch()
    
    /// Request the file that was fetched be deleted. Once the file
    /// has been deleted, it should notify the delegate.
    ///
    /// Implementations of `delete` should be idempotent, if a
    /// task is in the process of deleting the file, it should
    /// not raise an error.
    func delete()
    
    var downloadProgress: Float { get }
    var key: String { get }
    weak var delegate: DownloadTaskDelegate? { get set }
}



public enum DownloadTaskState {
    case progress(Float)
    case completed
    case error(Error)
    case deleted
}

public protocol NewDownloadTask: AnyObject {
    
    func fetch()
    func delete()
    
    var statePublisher: PassthroughSubject<DownloadTaskState, Never> { get }
    
    var key: String { get }
}

public class URLDownloadTask: NSObject, NewDownloadTask, URLSessionDownloadDelegate {
    public var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    public var key: String
    
    private var downloadURL: URL
    private var session: URLSession
    private var downloadTask: URLSessionDownloadTask?
    private var cancellables: Set<AnyCancellable> = []
    
    init(url: URL, key: String) {
        self.downloadURL = url
        self.key = key
        self.session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        super.init()
    }
    
    public func fetch() {
        guard downloadTask == nil else {
            return
        }
        
        downloadTask = session.downloadTask(with: downloadURL) { [weak self] location, response, error in
            guard let self = self else { return }
            if let error = error {
                self.statePublisher.send(.error(error))
            } else if let location = location {
                self.statePublisher.send(.completed)
            }
        }
        
        downloadTask?.progress.publisher(for: \.fractionCompleted)
            .map { DownloadTaskState.progress(Float($0)) }
            .subscribe(self.statePublisher)
            .store(in: &cancellables)
        
        downloadTask?.resume()
    }
    
    public func delete() {
        statePublisher.send(.deleted)
    }
}

extension URLDownloadTask {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        statePublisher.send(.completed)
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            statePublisher.send(.error(error))
        }
    }
}
