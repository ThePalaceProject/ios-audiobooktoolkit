//
//  DownloadTask.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier 4/11/2024
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Foundation
import Combine

public enum DownloadTaskState {
    case progress(Float)
    case completed
    case error(Error?)
    case deleted
}

public protocol DownloadTask: AnyObject {
    
    func fetch()
    func delete()
    
    var statePublisher: PassthroughSubject<DownloadTaskState, Never> { get }
    
    var key: String { get }
}

public class URLDownloadTask: NSObject, DownloadTask, URLSessionDownloadDelegate {
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
        downloadTask?.cancel()
        statePublisher.send(.deleted)
    }
}

extension URLDownloadTask {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if verifyDownload(location: location) {
            statePublisher.send(.completed)
        } else {
            statePublisher.send(.error(NSError(domain: "Download Verification Failed", code: -1, userInfo: nil)))
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            statePublisher.send(.error(error))
        }
    }
    
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        statePublisher.send(.progress(progress))
    }
}

extension URLDownloadTask {
    private func verifyDownload(location: URL) -> Bool {
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: location.path),
              let fileSize = fileAttributes[.size] as? UInt64, fileSize > 0 else {
            ATLog(.error, "Downloaded file does not exist or is empty.")
            return false
        }
        
        if !isCorrectFileType(at: location) {
            ATLog(.error, "Downloaded file type does not match expected.")
            return false
        }
        
        return true
    }
    
    private func isCorrectFileType(at url: URL) -> Bool {
        let expectedFileTypes = ["mp3", "mp4"]
        let fileExtension = url.pathExtension.lowercased()
        
        return expectedFileTypes.contains(fileExtension)
    }
}
