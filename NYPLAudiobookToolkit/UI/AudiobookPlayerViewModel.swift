//
//  AudiobookPlayerViewModel.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 11/28/22.
//

import Foundation
import Combine

class AudiobookPlayerViewModel {

    @Published var waitingForPlayer = false

    public var currentChapterLocation: ChapterLocation? {
        audiobookManager.audiobook.player.currentChapterLocation
    }
    
    private let audiobookManager: AudiobookManager

    init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
    }
}
