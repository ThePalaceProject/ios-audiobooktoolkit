//
//  AudiobookViewController.swift
//  NYPLAudibookKit
//
//  Created by Dean Silfen on 1/11/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import Foundation
import PureLayout
import AVKit
import MediaPlayer

public final class AudiobookDetailViewController: UIViewController {

    private let audiobookManager: AudiobookManager
    private var currentChapter: ChapterLocation? {
        return self.audiobookManager.audiobook.player.currentChapterLocation
    }

    public required init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        self.tintColor = UIColor.red
        super.init(nibName: nil, bundle: nil)
        self.audiobookManager.timerDelegate = self
        self.audiobookManager.downloadDelegate = self
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let padding = CGFloat(8)
    private let seekBar = ScrubberView()
    private let tintColor: UIColor
    private let playbackControlView = PlaybackControlView()
    private let speedBarButtonIndex = 1
    private let sleepTimerBarButtonIndex = 5
    private let audioRoutingBarButtonIndex = 3
    private let sleepTimerDefaultText = "☾"
    private let sleepTimerDefaultAccessibilityLabel = NSLocalizedString("Sleep Timer", bundle: Bundle.audiobookToolkit()!, value: "Sleep Timer", comment:"Sleep Timer")
    private let coverView: UIImageView = { () -> UIImageView in
        let imageView = UIImageView()
        imageView.image = UIImage(named: "example_cover", in: Bundle.audiobookToolkit(), compatibleWith: nil)
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityIdentifier = "cover_art"
        imageView.layer.cornerRadius = 10
        imageView.layer.masksToBounds = true
        imageView.contentMode = UIViewContentMode.scaleAspectFill
        return imageView
    }()

    private let toolbar = UIToolbar()
    private let chapterInfoStack = ChapterInfoStack()
    private let toolbarHeight: CGFloat = 44
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        self.navigationController?.navigationBar.isTranslucent = false
        self.navigationController?.navigationBar.tintColor = self.tintColor

        let gradiant = CAGradientLayer()
        gradiant.frame = self.view.bounds
        let startColor = UIColor(red: (210 / 255), green: (217 / 255), blue: (221 / 255), alpha: 1).cgColor
        gradiant.colors = [ startColor, UIColor.white.cgColor]
        gradiant.startPoint = CGPoint.zero
        gradiant.endPoint = CGPoint(x: 1, y: 1)
        self.view.layer.insertSublayer(gradiant, at: 0)
        let tocImage = UIImage(
            named: "table_of_contents",
            in: Bundle.audiobookToolkit(),
            compatibleWith: nil
        )
        let bbi = UIBarButtonItem(
            image: tocImage,
            style: .plain,
            target: self,
            action: #selector(AudiobookDetailViewController.tocWasPressed)
        )
        self.navigationItem.rightBarButtonItem = bbi
    
        self.view.addSubview(self.chapterInfoStack)
        self.chapterInfoStack.autoPin(toTopLayoutGuideOf: self, withInset: self.padding)
        self.chapterInfoStack.autoPinEdge(.left, to: .left, of: self.view)
        self.chapterInfoStack.autoPinEdge(.right, to: .right, of: self.view)

        self.chapterInfoStack.titleText = self.audiobookManager.metadata.title
        self.chapterInfoStack.authors = self.audiobookManager.metadata.authors

        self.view.addSubview(self.seekBar)
        self.seekBar.delegate = self;
        self.seekBar.autoPinEdge(.top, to: .bottom, of: self.chapterInfoStack, withOffset: self.padding * 2)
        self.seekBar.autoPinEdge(.top, to: .bottom, of: self.chapterInfoStack, withOffset: self.padding, relation: .greaterThanOrEqual)
        self.seekBar.autoPinEdge(.left, to: .left, of: self.view, withOffset: self.padding * 2)
        self.seekBar.autoPinEdge(.right, to: .right, of: self.view, withOffset: -(self.padding * 2))

        self.view.addSubview(self.coverView)
        self.coverView.autoPinEdge(.top, to: .bottom, of: self.seekBar, withOffset: self.padding * 2, relation: .greaterThanOrEqual)
        self.coverView.autoPinEdge(.top, to: .bottom, of: self.seekBar, withOffset: self.padding * 4, relation: .lessThanOrEqual)
        self.coverView.autoMatch(.width, to: .height, of: self.coverView, withMultiplier: 1)
        self.coverView.autoAlignAxis(.vertical, toSameAxisOf: self.view)

        self.view.addSubview(self.playbackControlView)
        self.view.addSubview(self.toolbar)

        self.playbackControlView.delegate = self
        self.playbackControlView.autoPinEdge(.top, to: .bottom, of: self.coverView, withOffset: (self.padding * 2), relation: .greaterThanOrEqual)
        self.playbackControlView.autoPinEdge(.bottom, to: .top, of: self.toolbar, withOffset: -(self.padding * 2))
        self.playbackControlView.autoPinEdge(.left, to: .left, of: self.view, withOffset: 0, relation: .greaterThanOrEqual)
        self.playbackControlView.autoPinEdge(.right, to: .right, of: self.view, withOffset: 0, relation: .lessThanOrEqual)
        self.playbackControlView.autoAlignAxis(.vertical, toSameAxisOf: self.view)
        self.coverView.addGestureRecognizer(
            UITapGestureRecognizer(
                target: self,
                action: #selector(AudiobookDetailViewController.coverArtWasPressed(_:))
            )
        )
        guard let chapter = self.currentChapter else { return }

        self.toolbar.autoPin(toBottomLayoutGuideOf: self, withInset: 0)
        self.toolbar.autoPinEdge(.left, to: .left, of: self.view)
        self.toolbar.autoPinEdge(.right, to: .right, of: self.view)
        self.toolbar.autoSetDimension(.height, toSize: self.toolbarHeight)
        self.toolbar.layer.borderWidth = 1
        self.toolbar.layer.borderColor = UIColor.white.cgColor
        let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        var items: [UIBarButtonItem] = [flexibleSpace, flexibleSpace, flexibleSpace, flexibleSpace]
        let playbackSpeedText = HumanReadablePlaybackRate(rate: self.audiobookManager.audiobook.player.playbackRate).value
        let speed =  UIBarButtonItem(
            title: playbackSpeedText,
            style: .plain,
            target: self,
            action: #selector(AudiobookDetailViewController.speedWasPressed(_:))
        )
        speed.accessibilityLabel = self.playbackSpeedTextFor(speedText: playbackSpeedText)
        speed.tintColor = self.tintColor
        items.insert(speed, at: self.speedBarButtonIndex)

        let audioRoutingItem = self.audioRoutingBarButtonItem()
        items.insert(audioRoutingItem, at: self.audioRoutingBarButtonIndex)
        let texts = self.textsFor(sleepTimer: self.audiobookManager.sleepTimer, chapter: chapter)
        let sleepTimer = UIBarButtonItem(
            title: texts.title,
            style: .plain,
            target: self,
            action: #selector(AudiobookDetailViewController.sleepTimerWasPressed(_:))
        )
        sleepTimer.tintColor = self.tintColor
        sleepTimer.accessibilityLabel = texts.accessibilityLabel

        items.insert(sleepTimer, at: self.sleepTimerBarButtonIndex)
        self.toolbar.setItems(items, animated: true)
        self.seekBar.setOffset(
            chapter.playheadOffset,
            duration: chapter.duration,
            timeLeftInBook: self.timeLeftAfter(chapter: chapter),
            middleText: self.middleTextFor(chapter: chapter)
        )
    }
    
    func timeLeftAfter(chapter: ChapterLocation) -> TimeInterval {
        let spine = self.audiobookManager.audiobook.spine
        var addUpStuff = false
        let timeLeftInChapter = chapter.timeRemaining
        let timeLeftAfterChapter = spine.reduce(timeLeftInChapter, { (result, element) -> TimeInterval in
            var newResult: TimeInterval = 0
            if addUpStuff {
                newResult = result + element.chapter.duration
            }

            if element.chapter.inSameChapter(other: self.currentChapter) {
                newResult = timeLeftInChapter
                addUpStuff = true
            }
            return newResult
        })
        return timeLeftAfterChapter
    }

    @objc public func tocWasPressed(_ sender: Any) {
        let tbvc = AudiobookTableOfContentsTableViewController(tableOfContents: self.audiobookManager.tableOfContents)
        self.navigationController?.pushViewController(tbvc, animated: true)
    }

    
    @objc public func speedWasPressed(_ sender: Any) {
        func actionFrom(rate: PlaybackRate, player: Player) -> UIAlertAction {
            let handler = { (_ action: UIAlertAction) -> Void in
                player.playbackRate = rate
                self.speedButtonShouldUpdate(rate: rate)
            }
            let title = HumanReadablePlaybackRate(rate: rate).value
            return UIAlertAction(title: title, style: .default, handler: handler)
        }
        
        let actionSheetTitle = NSLocalizedString("Set Your Play Speed", bundle: Bundle.audiobookToolkit()!, value: "Set Your Play Speed", comment: "Set Your Play Speed")
        let actionSheet = UIAlertController(title: actionSheetTitle, message: nil, preferredStyle: .actionSheet)
        let triggers: [PlaybackRate] = [.threeQuartersTime, .normalTime, .oneAndAQuarterTime, .oneAndAHalfTime, .doubleTime ]
        triggers.forEach { (trigger)  in
            let alert = actionFrom(rate: trigger, player: self.audiobookManager.audiobook.player)
            actionSheet.addAction(alert)
        }
        let cancelActionTitle = NSLocalizedString("Cancel", bundle: Bundle.audiobookToolkit()!, value: "Cancel", comment: "Cancel")
        actionSheet.addAction(UIAlertAction(title: cancelActionTitle, style: .cancel, handler: nil))
        self.present(actionSheet, animated: true, completion: nil)
    }

    func speedButtonShouldUpdate(rate: PlaybackRate) {
        if let buttonItem = self.toolbar.items?[self.speedBarButtonIndex] {
            let playbackSpeedText = HumanReadablePlaybackRate(rate: rate).value
            buttonItem.title = playbackSpeedText
            buttonItem.accessibilityLabel = self.playbackSpeedTextFor(speedText: playbackSpeedText)
        }
    }
    
    @objc public func sleepTimerWasPressed(_ sender: Any) {
        func actionFrom(trigger: SleepTimerTriggerAt, sleepTimer: SleepTimer) -> UIAlertAction {
            let handler = { (_ action: UIAlertAction) -> Void in
                sleepTimer.setTimerTo(trigger: trigger)
            }
            var action: UIAlertAction! = nil
            switch trigger {
            case .endOfChapter:
                let title = NSLocalizedString("End of Chapter", bundle: Bundle.audiobookToolkit()!, value: "End of Chapter", comment: "End of Chapter")
                action = UIAlertAction(title: title, style: .default, handler: handler)
            case .oneHour:
                action = UIAlertAction(title: "60", style: .default, handler: handler)
            case .thirtyMinutes:
                action = UIAlertAction(title: "30", style: .default, handler: handler)
            case .fifteenMinutes:
                action = UIAlertAction(title: "15", style: .default, handler: handler)
            case .never:
                let title = NSLocalizedString("Off", bundle: Bundle.audiobookToolkit()!, value: "Off", comment: "Off")
                action = UIAlertAction(title: title, style: .default, handler: handler)
            }
            return action
        }
        let title = NSLocalizedString("Set Your Sleep Timer", bundle: Bundle.audiobookToolkit()!, value: "Set Your Sleep Timer", comment: "Set Your Sleep Timer")
        let actionSheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        let triggers: [SleepTimerTriggerAt] = [.never, .fifteenMinutes, .thirtyMinutes, .oneHour, .endOfChapter]
        triggers.forEach { (trigger)  in
            let alert = actionFrom(trigger: trigger, sleepTimer: self.audiobookManager.sleepTimer)
            actionSheet.addAction(alert)
        }
        let cancelActionTitle = NSLocalizedString("Cancel", bundle: Bundle.audiobookToolkit()!, value: "Cancel", comment: "Cancel")
        actionSheet.addAction(UIAlertAction(title: cancelActionTitle, style: .cancel, handler: nil))
        self.present(actionSheet, animated: true, completion: nil)
    }

    @objc func coverArtWasPressed(_ sender: Any) { }
    
    func audioRoutingBarButtonItem() -> UIBarButtonItem {
        let view: UIView
        if #available(iOS 11.0, *) {
            view = AVRoutePickerView()
        } else {
            let volumeView = MPVolumeView()
            volumeView.showsVolumeSlider = false
            volumeView.showsRouteButton = true
            volumeView.sizeToFit()
            view = volumeView
        }
        view.tintColor = self.tintColor
        let buttonItem = UIBarButtonItem(customView: view)
        buttonItem.isAccessibilityElement = true
        buttonItem.accessibilityLabel = NSLocalizedString("Airplay", bundle: Bundle.audiobookToolkit()!, value: "Airplay", comment: "Airplay")
        buttonItem.accessibilityTraits = UIAccessibilityTraitButton
        return buttonItem
    }
    
    func updateTemporalUIElements() {
        if let chapter = self.currentChapter {
            if !self.seekBar.scrubbing {
                let timeLeftInBook = self.timeLeftAfter(chapter: chapter)
                self.seekBar.setOffset(
                    chapter.playheadOffset,
                    duration: chapter.duration,
                    timeLeftInBook: timeLeftInBook,
                    middleText: self.middleTextFor(chapter: chapter)
                )
            }
            
            if let barButtonItem = self.toolbar.items?[self.sleepTimerBarButtonIndex] {
                let texts = self.textsFor(sleepTimer: self.audiobookManager.sleepTimer, chapter: chapter)
                barButtonItem.title = texts.title
                barButtonItem.accessibilityLabel = texts.accessibilityLabel
            }
        }
        
        if self.audiobookManager.audiobook.player.isPlaying {
            self.playbackControlView.showPauseButton()
        } else {
            self.playbackControlView.showPlayButton()
        }
    }
    
    func textsFor(sleepTimer: SleepTimer, chapter: ChapterLocation) -> (title: String, accessibilityLabel: String) {
        let title: String
        let accessibilityLabel: String
        if sleepTimer.isScheduled {
            let timeRemaining: TimeInterval
            if sleepTimer.trigger == .endOfChapter {
                timeRemaining = chapter.timeRemaining
            } else {
                timeRemaining = sleepTimer.timeRemaining
            }
            title = HumanReadableTimestamp(timeInterval: timeRemaining).value
            let voiceOverTimeRemaining = VoiceOverTimestamp(
                timeInterval: timeRemaining
            ).value
            let middleTextFormat = NSLocalizedString("%@ until playback pauses", bundle: Bundle.audiobookToolkit()!, value: "%@ until playback pauses", comment: "some amount of localized time until playback pauses")
            accessibilityLabel = String(format: middleTextFormat, voiceOverTimeRemaining)
        } else {
            title = self.sleepTimerDefaultText
            accessibilityLabel = self.sleepTimerDefaultAccessibilityLabel
        }
        return (title: title, accessibilityLabel: accessibilityLabel)
    }

    func middleTextFor(chapter: ChapterLocation) -> String {
        let middleTextFormat = NSLocalizedString("Chapter %d of %d", bundle: Bundle.audiobookToolkit()!, value: "Chapter %d of %d", comment: "Chapter C of  L")
        return String(format: middleTextFormat, chapter.number, self.audiobookManager.audiobook.spine.count)
    }

    func playbackSpeedTextFor(speedText: String) -> String {
        let speedAccessibilityFormatString = NSLocalizedString("Playback speed %@", bundle: Bundle.audiobookToolkit()!, value: "Playback speed %@", comment: "Used for voice over")
        return String(format: speedAccessibilityFormatString, speedText)
    }
}

extension AudiobookDetailViewController: AudiobookManagerTimerDelegate {
    public func audiobookManager(_ audiobookManager: AudiobookManager, didUpdate timer: Timer?) {
        self.updateTemporalUIElements()
    }
}

extension AudiobookDetailViewController: PlaybackControlViewDelegate {
    func playbackControlViewSkipBackButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        self.audiobookManager.audiobook.player.skipBack()
    }
    
    func playbackControlViewSkipForwardButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        self.audiobookManager.audiobook.player.skipForward()
    }
    
    // Pausing happens almost instantly so we ask the manager to pause and pause the seek bar at the same time. However playback can take time to start up and we need to wait to move the seek bar until we here playback has began from the manager. This is because playing could require downloading the track.
    func playbackControlViewPlayButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        if self.audiobookManager.audiobook.player.isPlaying {
            self.audiobookManager.audiobook.player.pause()
        } else {
            self.audiobookManager.audiobook.player.play()
        }
    }
}

extension AudiobookDetailViewController: AudiobookManagerDownloadDelegate {
    public func audiobookManager(_ audiobookManager: AudiobookManager, didBecomeReadyForPlayback spineElement: SpineElement) { }
    public func audiobookManager(_ audiobookManager: AudiobookManager, didUpdateDownloadPercentageFor spineElement: SpineElement) { }
    public func audiobookManager(_ audiobookManager: AudiobookManager, didReceive error: NSError, for spineElement: SpineElement) {
        let errorLocalizedText = NSLocalizedString("Error!", bundle: Bundle.audiobookToolkit()!, value: "Error!", comment: "Error!")
        let alertController = UIAlertController(
            title: errorLocalizedText,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        let okLocalizedText = NSLocalizedString("Ok", bundle: Bundle.audiobookToolkit()!, value: "Ok", comment: "Ok")
        alertController.addAction(UIAlertAction(title: okLocalizedText, style: .cancel, handler: nil))
        self.present(alertController, animated: false, completion: nil)
    }
}

extension AudiobookDetailViewController: ScrubberViewDelegate {
    func scrubberView(_ scrubberView: ScrubberView, didRequestScrubTo offset: TimeInterval) {
        if let chapter = self.currentChapter?.chapterWith(offset) {
            self.audiobookManager.audiobook.player.jumpToLocation(chapter)
        }
    }

    func scrubberViewDidRequestAccessibilityIncrement(_ scrubberView: ScrubberView) {
        self.audiobookManager.audiobook.player.skipForward()
    }

    func scrubberViewDidRequestAccessibilityDecrement(_ scrubberView: ScrubberView) {
        self.audiobookManager.audiobook.player.skipBack()
    }
}

