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
    var bookmarks: [ChapterLocation]
    private let player: Player

    init(player: Player, bookmarks: [ChapterLocation]) {
        self.player = player
        self.bookmarks = bookmarks.sorted {
            let formatter = ISO8601DateFormatter()
            guard let date1 = formatter.date(from: $0.lastSavedTimeStamp),
                  let date2 = formatter.date(from: $1.lastSavedTimeStamp)
            else {
                return false
            }
            return date1 > date2
        }
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
        self.delegate?.audiobookTableOfContentsPendingStatusDidUpdate(inProgress: true)
    }

    private func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        true
    }
    
    private func tableView(tableView: UITableView, canEditRowAtIndexPath indexPath: NSIndexPath) -> Bool {
        true
    }
    public func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            delegate?.audiobookBookmarksUserDeletedBookmark(at: bookmarks[indexPath.row]) { success in
                guard success else {
                    return
                }

                DispatchQueue.main.async {
                    self.bookmarks.remove(at: indexPath.row)
                    tableView.reloadData()
                }
            }
        }
    }
}

