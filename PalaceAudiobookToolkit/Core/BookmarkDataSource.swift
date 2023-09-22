//
//  BookmarkDataSource.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import UIKit

protocol BookmarkDataSourceDelegate: class {
    func audiobookBookmarksUserSelected(location: ChapterLocation)
    func reloadBookmarks()
}

public class BookmarkDataSource: NSObject {
    weak var delegate: BookmarkDataSourceDelegate?
    var bookmarks: [ChapterLocation] { audiobookManager.audiobookBookmarks }
    var audiobookManager: AudiobookManager
    
    private let player: Player

    init(player: Player, audiobookManager: AudiobookManager) {
        self.player = player
        self.audiobookManager = audiobookManager
    }
    
    func fetchBookmarks(completion: @escaping () -> Void) {
        audiobookManager.fetchBookmarks { _ in
            completion()
        }
    }
}
