//
//  AudiobookTableOfContentsTableViewController.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/22/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

let AudiobookTableOfContentsTableViewControllerCellIdentifier = "AudiobookTableOfContentsTableViewControllerCellIdentifier"
let BookmarkDataSourceCellIdentifier = "BookmarkDataSourceCellIdentifier"

public protocol AudiobookTableOfContentsTableViewControllerDelegate {
    func userSelected(location: ChapterLocation)
}

public class AudiobookTableOfContentsTableViewController: UIViewController {
    typealias DisplayStrings = Strings.AudiobookTableOfContentsTableViewController

    let tableOfContents: AudiobookTableOfContents
    let bookmarkDataSource: BookmarkDataSource
    let delegate: AudiobookTableOfContentsTableViewControllerDelegate
    private let activityIndicator: UIActivityIndicatorView
    let segmentedControl = UISegmentedControl(items: [DisplayStrings.chapters, DisplayStrings.bookmarks])
    let tableView = UITableView()

    public init(tableOfContents: AudiobookTableOfContents, delegate: AudiobookTableOfContentsTableViewControllerDelegate, bookmarkDataSource: BookmarkDataSource) {
        self.tableOfContents = tableOfContents
        self.delegate = delegate
        self.bookmarkDataSource = bookmarkDataSource
        self.activityIndicator = UIActivityIndicatorView(style: .medium)
        self.activityIndicator.hidesWhenStopped = true
        super.init(nibName: nil, bundle: nil)
        let activityItem = UIBarButtonItem(customView: self.activityIndicator)
        self.navigationItem.rightBarButtonItems = [activityItem]
        self.tableOfContents.delegate = self
        self.bookmarkDataSource.delegate = self
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        view.addSubview(segmentedControl)

        tableView.dataSource = self.tableOfContents
        tableView.delegate = self.tableOfContents
        view.addSubview(tableView)

        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        tableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 50),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -50),

            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 20),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: AudiobookTableOfContentsTableViewControllerCellIdentifier)
        tableView.register(BookmarkTableViewCell.self, forCellReuseIdentifier: BookmarkDataSourceCellIdentifier)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let index = self.tableOfContents.currentSpineIndex() {
            self.tableView.reloadData()
            if self.tableView.numberOfRows(inSection: 0) > index {
                let indexPath = IndexPath(row: index, section: 0)
                self.tableView.selectRow(at: indexPath, animated: false, scrollPosition: .top)
                self.announceTrackIfNeeded(track: indexPath)
            }
        }
    }

    private func announceTrackIfNeeded(track: IndexPath) {
        if UIAccessibility.isVoiceOverRunning {
            let cell = self.tableView.cellForRow(at: track)
            let accessibleString = DisplayStrings.currentlyPlaying
            if let text = cell?.textLabel?.text {
                UIAccessibility.post(notification: .screenChanged, argument: String(format: accessibleString, text))
            }
        }
    }
    
    @objc func segmentChanged() {
        if segmentedControl.selectedSegmentIndex == 0 {
            tableView.dataSource = self.tableOfContents
            tableView.delegate = self.tableOfContents
        } else {
            tableView.dataSource = self.bookmarkDataSource
            tableView.delegate = self.bookmarkDataSource
        }
        tableView.reloadData()
    }
}

extension AudiobookTableOfContentsTableViewController: AudiobookTableOfContentsDelegate {
    func audiobookTableOfContentsDidRequestReload(_ audiobookTableOfContents: AudiobookTableOfContents) {
        if let selectedIndexPath = self.tableView.indexPathForSelectedRow {
            self.tableView.reloadData()
            self.tableView.selectRow(at: selectedIndexPath, animated: false, scrollPosition: .none)
        } else {
            self.tableView.reloadData()
        }
    }

    func audiobookTableOfContentsPendingStatusDidUpdate(inProgress: Bool) {
        if inProgress {
            self.activityIndicator.startAnimating()
        } else {
            self.activityIndicator.stopAnimating()
        }
    }
    

    func audiobookTableOfContentsUserSelected(spineItem: SpineElement) {
        self.delegate.userSelected(location: spineItem.chapter)
    }

    func audiobookBookmarksUserSelected(location: ChapterLocation) {
        self.delegate.userSelected(location: location)
    }
}
