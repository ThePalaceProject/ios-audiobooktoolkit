//
//  BookmarkDataSource.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 4/13/23.
//  Copyright © 2023 Dean Silfen. All rights reserved.
//

import UIKit

protocol BookmarkDataSourceDelegate: class {
    func audiobookBookmarksUserSelected(location: ChapterLocation)
    func reloadBookmarks()
}

public class BookmarkDataSource: NSObject, UITableViewDataSource {
    weak var delegate: BookmarkDataSourceDelegate?
    var bookmarks: [ChapterLocation] { audiobookManager.audiobookBookmarks }
    var audiobookManager: AudiobookManager
    
    private let player: Player

    init(player: Player, audiobookManager: AudiobookManager) {
        self.player = player
        self.audiobookManager = audiobookManager
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: BookmarkDataSourceCellIdentifier, for: indexPath) as? BookmarkTableViewCell else { return UITableViewCell() }
        
        guard let bookmark = bookmarks[safe: indexPath.row] else { return cell }
        cell.titleLabel.text = bookmark.title
        cell.subtitleLabel.text = DateFormatter.convertISO8601String(bookmark.lastSavedTimeStamp)

        let time = Date(timeIntervalSinceReferenceDate: bookmark.actualOffset)
        cell.rightLabel.text = DateFormatter.bookmarkTimeFormatter.string(from: time)
        
        return cell
    }
    
    func fetchBookmarks(completion: @escaping () -> Void) {
        audiobookManager.fetchBookmarks { _ in
            completion()
        }
    }
}

extension BookmarkDataSource: UITableViewDelegate {
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        60
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        bookmarks.count
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let chapterLocation = self.bookmarks[indexPath.row]
        self.player.playAtLocation(chapterLocation, completion: nil)
        self.delegate?.audiobookBookmarksUserSelected(location: chapterLocation)
    }

    private func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        true
    }
    
    private func tableView(tableView: UITableView, canEditRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        true
    }

    public func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            audiobookManager.deleteBookmark(at: bookmarks[indexPath.row]) { _ in
                self.delegate?.reloadBookmarks()
            }
        }
    }
}

