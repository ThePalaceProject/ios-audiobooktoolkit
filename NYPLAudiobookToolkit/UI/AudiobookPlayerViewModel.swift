//
//  AudiobookPlayerViewModel.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 11/28/22.
//

import Foundation
import Combine

class AudiobookPlayerViewModel {

    private let audiobookManager: AudiobookManager

    @Published var currentChapterLocation: ChapterLocation?
    
//    public var currentChapterLocation: ChapterLocation? {
//        audiobookManager.audiobook.player.currentChapterLocation
//    }

    init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        subscribeToPublishers()
    }
    
    func subscribeToPublishers() {
        
    }
    
    
}
