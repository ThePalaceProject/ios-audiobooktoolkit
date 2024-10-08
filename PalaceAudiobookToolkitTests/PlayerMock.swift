//
//  PlayerMock.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Dean Silfen on 3/7/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import PalaceAudiobookToolkit
import Combine

class PlayerMock: NSObject, Player {
    var currentOffset: Double = 0
    var isPlaying: Bool = false
    var queuesEvents: Bool = false
    var isDrmOk: Bool = true
    var isLoaded: Bool = false
    var tableOfContents: PalaceAudiobookToolkit.AudiobookTableOfContents
    var currentTrackPosition: PalaceAudiobookToolkit.TrackPosition?
    var playbackRate: PalaceAudiobookToolkit.PlaybackRate = .normalTime
    var playbackStatePublisher: PassthroughSubject<PalaceAudiobookToolkit.PlaybackState, Never> = PassthroughSubject()
    var currentChapter: PalaceAudiobookToolkit.Chapter?
    
    required init(tableOfContents: PalaceAudiobookToolkit.AudiobookTableOfContents) {
        self.tableOfContents = tableOfContents
        self.playbackStatePublisher = PassthroughSubject()
    }
    
    func skipPlayhead(_ timeInterval: TimeInterval, completion: ((PalaceAudiobookToolkit.TrackPosition?) -> Void)?) {
        completion?(currentTrackPosition)
    }
    
    func play(at position: PalaceAudiobookToolkit.TrackPosition, completion: (((any Error)?) -> Void)?) {
        completion?(nil)
    }
    
    func play() {
        isPlaying = true
    }
    
    func pause() {
        isPlaying = false
    }
    
    func unload() {
        isPlaying = false
    }
    
    func playAtLocation(_ newLocation: TrackPosition, completion: Completion?) { }
    
    func movePlayheadToLocation(_ location: TrackPosition, completion: Completion?) { }
    func move(to value: Double, completion: ((PalaceAudiobookToolkit.TrackPosition?) -> Void)?) {}
}
