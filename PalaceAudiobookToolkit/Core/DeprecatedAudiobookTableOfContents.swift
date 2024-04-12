////
////  AudiobookTableOfContents.swift
////  NYPLAudiobookToolkit
////
////  Created by Dean Silfen on 1/22/18.
////  Copyright © 2018 Dean Silfen. All rights reserved.
////
//
//import UIKit
//import Combine
//
//protocol AudiobookTableOfContentsDelegate: class {
//    func audiobookTableOfContentsDidRequestReload(_ audiobookTableOfContents: DeprecatedAudiobookTableOfContents)
//    func audiobookTableOfContentsPendingStatusDidUpdate(inProgress: Bool)
//    func audiobookTableOfContentsUserSelected(spineItem: SpineElement)
//}
//
///// This class may be used in conjunction with a UITableView to create a fully functioning Table of
///// Contents UI for the current audiobook. To get a functioning ToC that works out of the box,
///// construct a AudiobookTableOfContentsTableViewController.
//public final class DeprecatedAudiobookTableOfContents: NSObject {
//    public private(set) var downloadProgress = CurrentValueSubject<Float, Never>(0.0)
//    private var cancellables: Set<AnyCancellable> = []
//
//    weak var delegate: AudiobookTableOfContentsDelegate?
//    private let networkService: AudiobookNetworkService
//    private let player: Player
//    internal init(networkService: AudiobookNetworkService, player: Player) {
//        self.networkService = networkService
//        self.player = player
//        super.init()
//        bindNetworkService()
//    }
//
//    private func bindNetworkService() {
//        networkService.downloadStatePublisher
//            .sink(receiveValue: { [weak self] downloadState in
//                guard let self = self else { return }
//                
//                switch downloadState {
//                case .progress(let track, _):
//                    // Assuming you can derive a SpineElement or similar identifier from the track
//                    // Update specific track progress
//                    self.notifyDelegateOfUpdate()
//                    
//                case .completed(let track):
//                    // Handle completion for a specific track
//                    self.notifyDelegateOfUpdate()
//                    
//                case .error(let track, let error):
//                    print("Download error for track \(track.id): \(error)")
//                    self.notifyDelegateOfUpdate()
//                    
//                case .overallProgress(let progress):
//                    // Update overall download progress
//                    self.downloadProgress.value = progress
//                    self.notifyDelegateOfUpdate()
//                case .deleted(let track):
//                    print("Deleted track \(track.id)")
//                    self.notifyDelegateOfUpdate()
//                }
//            })
//            .store(in: &cancellables)
//    }
//    
//    private func notifyDelegateOfUpdate() {
//        DispatchQueue.main.async { [weak self] in
//            self?.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: self?.downloadProgress.value ?? 0 < 1)
//            self?.delegate?.audiobookTableOfContentsDidRequestReload(self!)
//        }
//    }
//
//    func currentSpineIndex() -> Int? {
////        if let currentPlayingChapter = self.player.currentChapterLocation {
////            let spine = self.networkService.spine
////            for index in 0..<spine.count {
////                if currentPlayingChapter.inSameChapter(other: spine[index].chapter) {
////                    return index
////                }
////            }
////        }
//        return nil
//    }
//    
//    /// Download all available files from network for the current audiobook.
//    public func fetch() {
//        self.networkService.fetch()
//    }
//    
//    /// Delete all available files for the current audiobook.
//    public func deleteAll() {
//        self.networkService.deleteAll()
//    }
//}
//
//extension DeprecatedAudiobookTableOfContents: Original_PlayerDelegate {
//    public func player(_ player: OriginalPlayer, didBeginPlaybackOf chapter: ChapterLocation) {
//        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
//        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
//    }
//    
//    public func player(_ player: OriginalPlayer, didStopPlaybackOf chapter: ChapterLocation) {
//        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
//        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
//    }
//
//    public func player(_ player: OriginalPlayer, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?) { }
//    public func player(_ player: OriginalPlayer, didComplete chapter: ChapterLocation) { }
//    public func playerDidUnload(_ player: OriginalPlayer) { }
//}
//
////  AudiobookTableOfContents.swift
////  NYPLAudiobookToolkit
////
////  Created by Dean Silfen on 1/22/18.
////  Copyright © 2018 Dean Silfen. All rights reserved.
////
//
//import UIKit
//import Combine
//
//protocol AudiobookTableOfContentsDelegate: class {
//    func audiobookTableOfContentsDidRequestReload(_ audiobookTableOfContents: DeprecatedAudiobookTableOfContents)
//    func audiobookTableOfContentsPendingStatusDidUpdate(inProgress: Bool)
//    func audiobookTableOfContentsUserSelected(spineItem: SpineElement)
//}
//
///// This class may be used in conjunction with a UITableView to create a fully functioning Table of
///// Contents UI for the current audiobook. To get a functioning ToC that works out of the box,
///// construct a AudiobookTableOfContentsTableViewController.
//public final class DeprecatedAudiobookTableOfContents: NSObject {
//    public private(set) var downloadProgress = CurrentValueSubject<Float, Never>(0.0)
//    private var cancellables: Set<AnyCancellable> = []
//
//    weak var delegate: AudiobookTableOfContentsDelegate?
//    private let networkService: AudiobookNetworkService
//    private let player: Player
//    internal init(networkService: AudiobookNetworkService, player: Player) {
//        self.networkService = networkService
//        self.player = player
//        super.init()
//        bindNetworkService()
//    }
//
//    private func bindNetworkService() {
//        networkService.downloadStatePublisher
//            .sink(receiveValue: { [weak self] downloadState in
//                guard let self = self else { return }
//                
//                switch downloadState {
//                case .progress(let track, _):
//                    // Assuming you can derive a SpineElement or similar identifier from the track
//                    // Update specific track progress
//                    self.notifyDelegateOfUpdate()
//                    
//                case .completed(let track):
//                    // Handle completion for a specific track
//                    self.notifyDelegateOfUpdate()
//                    
//                case .error(let track, let error):
//                    print("Download error for track \(track.id): \(error)")
//                    self.notifyDelegateOfUpdate()
//                    
//                case .overallProgress(let progress):
//                    // Update overall download progress
//                    self.downloadProgress.value = progress
//                    self.notifyDelegateOfUpdate()
//                case .deleted(let track):
//                    print("Deleted track \(track.id)")
//                    self.notifyDelegateOfUpdate()
//                }
//            })
//            .store(in: &cancellables)
//    }
//    
//    private func notifyDelegateOfUpdate() {
//        DispatchQueue.main.async { [weak self] in
//            self?.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: self?.downloadProgress.value ?? 0 < 1)
//            self?.delegate?.audiobookTableOfContentsDidRequestReload(self!)
//        }
//    }
//
//    func currentSpineIndex() -> Int? {
////        if let currentPlayingChapter = self.player.currentChapterLocation {
////            let spine = self.networkService.spine
////            for index in 0..<spine.count {
////                if currentPlayingChapter.inSameChapter(other: spine[index].chapter) {
////                    return index
////                }
////            }
////        }
//        return nil
//    }
//    
//    /// Download all available files from network for the current audiobook.
//    public func fetch() {
//        self.networkService.fetch()
//    }
//    
//    /// Delete all available files for the current audiobook.
//    public func deleteAll() {
//        self.networkService.deleteAll()
//    }
//}
//
//extension DeprecatedAudiobookTableOfContents: Original_PlayerDelegate {
//    public func player(_ player: OriginalPlayer, didBeginPlaybackOf chapter: ChapterLocation) {
//        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
//        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
//    }
//    
//    public func player(_ player: OriginalPlayer, didStopPlaybackOf chapter: ChapterLocation) {
//        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: false)
//        self.delegate?.audiobookTableOfContentsDidRequestReload(self)
//    }
//
//    public func player(_ player: OriginalPlayer, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?) { }
//    public func player(_ player: OriginalPlayer, didComplete chapter: ChapterLocation) { }
//    public func playerDidUnload(_ player: OriginalPlayer) { }
//}
