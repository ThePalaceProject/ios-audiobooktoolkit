//
//  BookmarkDataSource.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 4/13/23.
//  Copyright © 2023 Dean Silfen. All rights reserved.
//

import UIKit

public class BookmarkDataSource: NSObject, UITableViewDataSource {
    weak var delegate: AudiobookTableOfContentsDelegate?
    private var bookmarks: [ChapterLocation]
    private let player: Player

    init(player: Player, bookmarks: [ChapterLocation]) {
        self.player = player
        self.bookmarks = bookmarks
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: BookmarkDataSourceCellIdentifier, for: indexPath) as? BookmarkTableViewCell else { return UITableViewCell() }
        
        let bookmark = bookmarks[indexPath.row]
        cell.titleLabel.text = bookmark.title
        
        if let lastSavedTimeStamp = bookmark.lastSavedTimeStamp {
            cell.subtitleLabel.text = DateFormatter.convertISO8601String(lastSavedTimeStamp)
        } else {
            cell.subtitleLabel.text = ""
        }
        
        let time = Date(timeIntervalSinceReferenceDate: bookmark.playheadOffset)
        cell.rightLabel.text = DateFormatter.bookmarkTimeFormatter.string(from: time)
        
        return cell
    }
}

extension BookmarkDataSource: UITableViewDelegate {
    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        60
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return bookmarks.count
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let chapterLocation = self.bookmarks[indexPath.row]
        self.player.playAtLocation(chapterLocation, completion: nil)
        self.delegate?.audiobookBookmarksUserSelected(location: chapterLocation)
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: true)
    }

    private func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            deleteBookmark(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
        }
    }

    private func deleteBookmark(at index: Int) {
        bookmarks.remove(at: index)
    }
}

