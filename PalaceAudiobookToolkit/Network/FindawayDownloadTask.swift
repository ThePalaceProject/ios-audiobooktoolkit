//
//  FindawayLibrarian.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/22/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import AudioEngine
import Combine

/// Handle network interactions with the AudioEngine SDK.
final class FindawayDownloadTask: DownloadTask {
    var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
    var key: String
    private var downloadRequest: FAEDownloadRequest
    private var session: URLSession?
    private var downloadTask: DownloadTask?

    var downloadProgress: Float = 0 {
        didSet {
            self.statePublisher.send(.progress(self.downloadProgress))
            self.notifiedDownloadProgress = self.downloadProgress
        }
    }

    private let pollRate: TimeInterval = 0.5
    private var pollAgainForPercentageAt: Date?
    private var retryAfterVerification = false
    private var readyToDownload: Bool {
        didSet {
            guard self.readyToDownload else { return }
            guard self.retryAfterVerification else { return }
            self.attemptFetch()
        }
    }
    
    private var downloadStatus: FAEDownloadStatus {
        var status = FAEDownloadStatus.notDownloaded
        guard self.readyToDownload else {
            return status
        }
        
        let statusFromFindaway = FAEAudioEngine.shared()?.downloadEngine?.status(
            forAudiobookID: self.downloadRequest.audiobookID,
            partNumber: self.downloadRequest.partNumber,
            chapterNumber: self.downloadRequest.chapterNumber
        )
        if let storedStatus = statusFromFindaway {
            status = storedStatus
        }
        return status
    }
    
    private var downloadEngineIsFree: Bool {
        guard self.readyToDownload else {
            return false
        }
        
        return FAEAudioEngine.shared()?.downloadEngine?.currentDownloadRequests().isEmpty ?? false
    }
    private let queue: DispatchQueue
    private var notifiedDownloadProgress: Float = Float.nan
    private let notificationHandler: FindawayDownloadNotificationHandler
    public init(databaseVerification: FindawayDatabaseVerification,
                findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler,
                downloadRequest: FAEDownloadRequest,
                key: String) {
        self.downloadRequest = downloadRequest
        self.notificationHandler = findawayDownloadNotificationHandler
        self.readyToDownload = databaseVerification.verified
        self.queue = DispatchQueue(label: "org.nypl.labs.PalaceAudiobookToolkit.FindawayDownloadTask/\(key)")
        self.key = key
        self.notificationHandler.delegate = self
        if !self.readyToDownload {
            databaseVerification.registerDelegate(self)
        }
    }

    convenience init(
        audiobookID: String,
        chapterNumber: UInt,
        partNumber: UInt,
        sessionKey: String,
        licenseID: String
    ) {
      var request: FAEDownloadRequest! = FAEAudioEngine.shared()?.downloadEngine?.currentDownloadRequests().first(where: { (existingRequest) -> Bool in
            return existingRequest.audiobookID == audiobookID
                && existingRequest.chapterNumber == chapterNumber
                && existingRequest.chapterNumber == partNumber
        })
        
        if request == nil {
            request = FAEDownloadRequest(
                audiobookID: audiobookID,
                partNumber: partNumber,
                chapterNumber: chapterNumber,
                downloadType: .singleChapter,
                sessionKey: sessionKey,
                licenseID: licenseID,
                restrictToWiFi: false
            )
        }
        self.init(
            databaseVerification: FindawayDatabaseVerification.shared,
            findawayDownloadNotificationHandler: DefaultFindawayDownloadNotificationHandler(),
            downloadRequest: request,
            key: "FAE.audioEngine/\(request.audiobookID)/\(request.partNumber)/\(request.chapterNumber)"
        )
    }

    /**
     This implementation of fetch() will wait until FAEAudioEngine has verified it's database
     before attempting a download. If this object never sees a verified database from updated AudiobookLifeCycleManager
     events, then it will never even hit the network.
     */
    public func fetch() {
        self.queue.sync {
            self.attemptFetch()
        }
    }

    private func attemptFetch() {
        guard self.readyToDownload else {
            self.retryAfterVerification = true
            return
        }

        let status = self.downloadStatus
        if status == .notDownloaded {
            FAEAudioEngine.shared()?.downloadEngine?.startDownload(with: self.downloadRequest)
            self.retryAfterVerification = false
        } else if status == .downloaded {
            self.statePublisher.send(.completed)
        }
    }

    func nextScheduledPoll() -> DispatchTime {
        return DispatchTime.now() + self.pollRate
    }

    func pollForDownloadPercentage() {
        func notifyDelegate() {
            guard let pollAt = self.pollAgainForPercentageAt else {
                return
            }

            if Date() > pollAt {
                if self.notifiedDownloadProgress != self.downloadProgress {
                    updateDownloadProgress()
                }
            }

            if self.downloadStatus == .downloading {
                self.pollForDownloadPercentage()
            } else {
                self.pollAgainForPercentageAt = nil
            }
        }

        self.queue.asyncAfter(deadline: self.nextScheduledPoll()) {
            notifyDelegate()
        }
    }
    
    private func updateDownloadProgress() {
        guard self.readyToDownload else {
            downloadProgress = 0
            return
        }
        
        downloadProgress = findawayProgressToNYPLToolkit(
            FAEAudioEngine.shared()?.downloadEngine?.percentage(
                forAudiobookID: self.downloadRequest.audiobookID,
                partNumber: self.downloadRequest.partNumber,
                chapterNumber: self.downloadRequest.chapterNumber
            )
        )
    }

    /// If we try to download the book again before the deletion has
    /// finished, AudioEngine will throw an error and fail the download.
    ///
    /// After the deletion has finished, we must aquire a new DownloadRequest
    /// in order to perform another download.
    ///
    /// To compensate for this, if `fetch` is called directly after `delete`,
    /// this object ought to wait until the new DownloadRequest is created
    /// and then attempt the `fetch` again.
    public func delete() {
        self.queue.sync {
            FAEAudioEngine.shared()?.downloadEngine?.delete(
                forAudiobookID: self.downloadRequest.audiobookID,
                partNumber: self.downloadRequest.partNumber,
                chapterNumber: self.downloadRequest.chapterNumber
            )
            self.readyToDownload = false
        }
    }
}

extension FindawayDownloadTask: FindawayDownloadNotificationHandlerDelegate {
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didPauseDownloadFor chapterDescription: FAEChapterDescription) {
        self.queue.sync {
            guard self.isTaskFor(chapterDescription) else { return }
            self.pollAgainForPercentageAt = nil
        }
    }

    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didSucceedDownloadFor chapterDescription: FAEChapterDescription) {
        self.queue.sync {
            guard self.isTaskFor(chapterDescription) else { return }
            self.pollAgainForPercentageAt = nil
            self.statePublisher.send(.completed)
        }
    }
    
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didStartDownloadFor chapterDescription: FAEChapterDescription) {
        self.queue.sync {
            guard self.isTaskFor(chapterDescription) else { return }
            guard self.pollAgainForPercentageAt == nil else { return }
            self.pollAgainForPercentageAt = Date().addingTimeInterval(self.pollRate)
            self.pollForDownloadPercentage()
        }
    }

    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didReceive error: NSError, for downloadRequestID: String) {
        self.queue.sync {
            if self.downloadRequest.requestIdentifier == downloadRequestID {
                self.pollAgainForPercentageAt = nil
                self.statePublisher.send(.error(error))
            }
        }
    }

    /// If a user attempts to download a book with a request thats already
    /// been deleted from the filesystem, then AudioEngine will throw an error.
    ///
    /// As a result of this, once we have confirmed that a chapter has been removed,
    /// we instantiate a new FAEDownloadRequest for our asset.
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didDeleteAudiobookFor chapterDescription: FAEChapterDescription) {
        self.queue.sync {
            if self.isTaskFor(chapterDescription) {
                self.statePublisher.send(.deleted)
                self.downloadRequest = FAEDownloadRequest(
                    audiobookID: self.downloadRequest.audiobookID,
                    partNumber: self.downloadRequest.partNumber,
                    chapterNumber: self.downloadRequest.chapterNumber,
                    downloadType: self.downloadRequest.downloadType,
                    sessionKey: self.downloadRequest.sessionKey,
                    licenseID: self.downloadRequest.licenseID,
                    restrictToWiFi: self.downloadRequest.restrictToWiFi
                )
                self.readyToDownload = true
            }
        }
    }
    
    func isTaskFor(_ chapter: FAEChapterDescription) -> Bool {
        return self.downloadRequest.audiobookID == chapter.audiobookID &&
                self.downloadRequest.chapterNumber == chapter.chapterNumber &&
                self.downloadRequest.partNumber == chapter.partNumber
    }
}

extension FindawayDownloadTask: FindawayDatabaseVerificationDelegate {
    func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification) {
        self.queue.sync {
            self.readyToDownload = findawayDatabaseVerification.verified
        }
    }
}

private func findawayProgressToNYPLToolkit(_ progress: Float?) -> Float {
    var toolkitProgress: Float = 0
    if let progress = progress {
        toolkitProgress = progress / 100
    }
    return toolkitProgress
}
