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

public protocol AudiobookTableOfContentsTableViewControllerDelegate: class {
    func userSelected(location: ChapterLocation)
    func fetchBookmarks(completion: @escaping ([ChapterLocation]) -> Void)
    func userDeletedBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void)
}

public class AudiobookTableOfContentsTableViewController: UIViewController {
    typealias DisplayStrings = Strings.AudiobookTableOfContentsTableViewController

    let tableOfContents: AudiobookTableOfContents
    let bookmarkDataSource: BookmarkDataSource
    weak var delegate: AudiobookTableOfContentsTableViewControllerDelegate?
    private let activityIndicator: UIActivityIndicatorView
    let segmentedControl = UISegmentedControl(items: [DisplayStrings.chapters, DisplayStrings.bookmarks])
    let tableView = UITableView()
    private var isLoading: Bool = false {
        didSet {
            DispatchQueue.main.async {
                if self.isLoading {
                    self.activityIndicator.startAnimating()
                } else {
                    self.activityIndicator.stopAnimating()
                }
            }
        }
    }

    public init(
        tableOfContents: AudiobookTableOfContents,
        bookmarkDataSource: BookmarkDataSource,
        delegate: AudiobookTableOfContentsTableViewControllerDelegate) {
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
        scrollToSelectedRow()
    }

    private func scrollToSelectedRow(_ animated: Bool = false) {
        if let index = self.tableOfContents.currentSpineIndex() {
            self.tableView.reloadData()
            if self.tableView.numberOfRows(inSection: 0) > index {
                let indexPath = IndexPath(row: index, section: 0)
                self.tableView.selectRow(at: indexPath, animated: animated, scrollPosition: .top)
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
            emptyView.removeFromSuperview()
            tableView.dataSource = self.tableOfContents
            tableView.delegate = self.tableOfContents
            scrollToSelectedRow(true)
            tableView.reloadData()
        } else {
            tableView.dataSource = self.bookmarkDataSource
            tableView.delegate = self.bookmarkDataSource
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
            reloadData()
        }
    }

    private func reloadData() {
        isLoading = true
    
        delegate?.fetchBookmarks { [unowned self] bookmarks in
            isLoading = false
            DispatchQueue.main.async {
                if bookmarks.isEmpty {
                    self.view.addSubview(self.emptyView)
                    
                    NSLayoutConstraint.activate([
                        self.emptyView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                        self.emptyView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                        self.emptyView.topAnchor.constraint(equalTo: self.segmentedControl.bottomAnchor),
                        self.emptyView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
                    ])
                } else {
                    self.emptyView.removeFromSuperview()
                }

                self.bookmarkDataSource.bookmarks = bookmarks
                self.tableView.reloadData()
            }
        }
    }

    private let emptyView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = NSLocalizedString("There are no bookmarks for this book.", comment: "")
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        return view
    }()
}

extension AudiobookTableOfContentsTableViewController: AudiobookTableOfContentsDelegate {
    func audiobookTableOfContentsDidRequestReload(_ audiobookTableOfContents: AudiobookTableOfContents) {
        if let selectedIndexPath = self.tableView.indexPathForSelectedRow {
            self.tableView.reloadData()
            self.tableView.selectRow(at: selectedIndexPath, animated: false, scrollPosition: .none)
        } else {
            reloadData()
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
        self.delegate?.userSelected(location: spineItem.chapter)
    }

    func audiobookBookmarksUserSelected(location: ChapterLocation) {
        self.delegate?.userSelected(location: location)
    }

    func audiobookBookmarksUserDeletedBookmark(at location: ChapterLocation, completion: @escaping (Bool) -> Void) {
        self.delegate?.userDeletedBookmark(at: location) { success in
            self.reloadData()
            completion(success)
        }
    }
}
