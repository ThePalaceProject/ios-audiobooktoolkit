//
//  AudiobookTableOfContents.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 1/22/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

protocol AudiobookTableOfContentsDelegate: class {
    func audiobookTableOfContentsDidRequestReload(_ audiobookTableOfContents: AudiobookTableOfContents)
    func audiobookTableOfContentsPendingStatusDidUpdate(inProgress: Bool)
    func audiobookTableOfContentsUserSelected(spineItem: SpineElement)
}

/// This class may be used in conjunction with a UITableView to create a fully functioning Table of
/// Contents UI for the current audiobook. To get a functioning ToC that works out of the box,
/// construct a AudiobookTableOfContentsTableViewController.
public final class AudiobookTableOfContents: NSObject {
    
    public var downloadProgress: Float {
        return self.networkService.downloadProgress
    }

    /// Download all available files from network for the current audiobook.
    public func fetch() {
        self.networkService.fetch()
    }

    /// Delete all available files for the current audiobook.
    public func deleteAll() {
        self.networkService.deleteAll()
    }

    weak var delegate: AudiobookTableOfContentsDelegate?
    private let networkService: AudiobookNetworkService
    private let player: OriginalPlayer
    internal init(networkService: AudiobookNetworkService, player: OriginalPlayer) {
        self.networkService = networkService
        self.player = player
        super.init()
        self.player.registerDelegate(self)
        self.networkService.registerDelegate(self)
    }
    
    deinit {
        self.player.removeDelegate(self)
        self.networkService.removeDelegate(self)
    }

    func currentSpineIndex() -> Int? {
        if let currentPlayingChapter = self.player.currentChapterLocation {
            let spine = self.networkService.spine
            for index in 0..<spine.count {
                if currentPlayingChapter.inSameChapter(other: spine[index].chapter) {
                    return index
                }
            }
        }
        return nil
    }
}

extension AudiobookTableOfContents: Original_PlayerDelegate {
    public func player(_ player: OriginalPlayer, didBeginPlaybackOf chapter: ChapterLocation) {
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
    }
    
    public func player(_ player: OriginalPlayer, didStopPlaybackOf chapter: ChapterLocation) {
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
    }

    public func player(_ player: OriginalPlayer, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?) { }
    public func player(_ player: OriginalPlayer, didComplete chapter: ChapterLocation) { }
    public func playerDidUnload(_ player: OriginalPlayer) { }
}

extension AudiobookTableOfContents: AudiobookNetworkServiceDelegate {
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didReceive error: NSError?, for spineElement: SpineElement) {
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
    }
    
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didCompleteDownloadFor spineElement: SpineElement) {
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
    }

    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didUpdateProgressFor spineElement: SpineElement)
 {
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
    }
    
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didDeleteFileFor spineElement: SpineElement) {
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
    }
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didUpdateOverallDownloadProgress progress: Float) { }
}
