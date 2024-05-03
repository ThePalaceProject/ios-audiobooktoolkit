//
//  FindawayDownloadNotificationHandler.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/26/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import AudioEngine

@objc public protocol FindawayDownloadNotificationHandlerDelegate: class {
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didReceive error: NSError, for downloadRequestID: String)
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didDeleteAudiobookFor chapterDescription: FAEChapterDescription)

    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didSucceedDownloadFor chapterDescription: FAEChapterDescription)
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didPauseDownloadFor chapterDescription: FAEChapterDescription)
    func findawayDownloadNotificationHandler(_ findawayDownloadNotificationHandler: FindawayDownloadNotificationHandler, didStartDownloadFor chapterDescription: FAEChapterDescription)
}

@objc public protocol FindawayDownloadNotificationHandler: class {
    weak var delegate: FindawayDownloadNotificationHandlerDelegate? { get set }
}

