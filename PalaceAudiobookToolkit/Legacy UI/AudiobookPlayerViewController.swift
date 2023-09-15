import UIKit
import Foundation
import PureLayout
import AVKit
import MediaPlayer

let SkipTimeInterval: Double = 15

@objcMembers public final class AudiobookPlayerViewController: UIViewController {
    typealias DisplayStrings = Strings.AudiobookPlayerViewController

    private let audiobookManager: AudiobookManager
    public var currentChapterLocation: ChapterLocation? {
        return self.audiobookManager.audiobook.player.currentChapterLocation
    }

    public required init(audiobookManager: AudiobookManager) {
        self.audiobookManager = audiobookManager
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let activityIndicator = BufferActivityIndicatorView(style: .gray)
    private let gradient = CAGradientLayer()
    private let padding = CGFloat(12)

    private let toolbar = UIToolbar()
    private let toolbarHeight: CGFloat = 44
    private let toolbarButtonWidth: CGFloat = 75.0

    private let audioRouteButtonWidth: CGFloat = 50.0
    private let speedBarButtonIndex = 1
    private let audioRoutingBarButtonIndex = 3
    private let sleepTimerBarButtonIndex = 5
    private let addBookmarBarButtonindex = 7
    private let sleepTimerDefaultText = "☾"
    private let sleepTimerDefaultAccessibilityLabel = DisplayStrings.sleepTimer

    private var audiobookProgressView = DownloadProgressView()

    private let chapterInfoStack = ChapterInfoStack()
    public var coverView: AudiobookCoverImageView = { () -> AudiobookCoverImageView in
        let image = UIImage(named: "example_cover", in: Bundle.audiobookToolkit(), compatibleWith: nil)
        let imageView = AudiobookCoverImageView.init(image: image)
        return imageView
    }()
    private let seekBar = ScrubberView()
    private let playbackControlView = PlaybackControlView()
    private var shouldBeginToAutoPlay = false
    private var waitingForPlayer = false {
        didSet {
            if !waitingForPlayer {
                self.activityIndicator.stopAnimating()
            }
        }
    }

    private var compactWidthConstraints: [NSLayoutConstraint]!
    private var regularWidthConstraints: [NSLayoutConstraint]!
    
    private var bookmarkButton: UIBarButtonItem {
        let button = UIButton(type: .system)
        button.setImage(UIImage(named: "bookmark", in: Bundle.audiobookToolkit(), compatibleWith: nil), for: .normal)
        button.sizeToFit()
        button.addTarget(self, action: #selector(addBookmark), for: .touchUpInside)
        let buttonItem = UIBarButtonItem(customView: button)
        
        buttonItem.isAccessibilityElement = true
        buttonItem.accessibilityLabel = DisplayStrings.addBookmark
        buttonItem.accessibilityHint = DisplayStrings.addBookmarkAccessiblityHint
        buttonItem.accessibilityTraits = UIAccessibilityTraits.button
        buttonItem.width = toolbarButtonWidth
        return buttonItem
    }

    //MARK:-

    deinit {
        ATLog(.debug, "AudiobookPlayerViewController has deinitialized.")
        self.audiobookManager.audiobook.player.unload()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        self.audiobookManager.audiobook.player.registerDelegate(self)
        self.audiobookManager.networkService.registerDelegate(self)
        self.audiobookManager.networkService.fetch()

        self.gradient.frame = self.view.bounds
        let startColor = UIColor(red: (210 / 255), green: (217 / 255), blue: (221 / 255), alpha: 1).cgColor
        self.gradient.colors = [ startColor, UIColor.white.cgColor]
        self.gradient.startPoint = CGPoint.zero
        self.gradient.endPoint = CGPoint(x: 1, y: 1)
        self.view.layer.insertSublayer(self.gradient, at: 0)
   
        let tocImage = UIImage(
            named: "table_of_contents",
            in: Bundle.audiobookToolkit(),
            compatibleWith: nil
        )
        let tocBbi = UIBarButtonItem(
            image: tocImage,
            style: .plain,
            target: self,
            action: #selector(AudiobookPlayerViewController.tocWasPressed)
        )
        tocBbi.width = audioRouteButtonWidth
        tocBbi.accessibilityLabel = DisplayStrings.tableOfContents
        tocBbi.accessibilityHint = DisplayStrings.chapterSelectionAccessibility

        self.activityIndicator.hidesWhenStopped = true
        let indicatorBbi = UIBarButtonItem(customView: self.activityIndicator)
        self.navigationItem.rightBarButtonItems = [ tocBbi, indicatorBbi ]

        self.view.addSubview(self.audiobookProgressView)
        self.audiobookProgressView.backgroundColor = .black
        self.audiobookProgressView.autoPinEdge(toSuperviewSafeArea: .top, withInset: 0)
        self.audiobookProgressView.autoPinEdge(toSuperviewEdge: .leading)
        self.audiobookProgressView.autoPinEdge(toSuperviewEdge: .trailing)

        self.chapterInfoStack.titleText = self.audiobookManager.metadata.title ?? "Audiobook"
        self.chapterInfoStack.authors = self.audiobookManager.metadata.authors ?? [""]

        self.view.addSubview(self.chapterInfoStack)
        self.chapterInfoStack.autoSetDimension(.width, toSize: 500, relation: .lessThanOrEqual)
        self.chapterInfoStack.autoAlignAxis(toSuperviewAxis: .vertical)
        self.chapterInfoStack.autoPinEdge(toSuperviewMargin: .leading, relation: .greaterThanOrEqual)
        self.chapterInfoStack.autoPinEdge(toSuperviewMargin: .trailing, relation: .greaterThanOrEqual)

        self.view.addSubview(self.coverView)

        self.coverView.autoPinEdge(toSuperviewMargin: .leading, relation: .greaterThanOrEqual)
        self.coverView.autoPinEdge(toSuperviewMargin: .trailing, relation: .greaterThanOrEqual)

        let playbackControlViewContainer = UIView()
        playbackControlViewContainer.addSubview(self.playbackControlView)
        self.view.addSubview(playbackControlViewContainer)
        self.view.addSubview(self.toolbar)
        self.playbackControlView.delegate = self
        self.playbackControlView.autoCenterInSuperview()
        self.playbackControlView.autoPinEdge(toSuperviewEdge: .leading, withInset: 0, relation: .greaterThanOrEqual)
        self.playbackControlView.autoPinEdge(toSuperviewEdge: .trailing, withInset: 0, relation: .greaterThanOrEqual)
        self.playbackControlView.autoPinEdge(toSuperviewEdge: .top, withInset: 0, relation: .greaterThanOrEqual)
        self.playbackControlView.autoPinEdge(toSuperviewEdge: .bottom, withInset: 0, relation: .greaterThanOrEqual)

        playbackControlViewContainer.autoSetDimension(.height, toSize: 75, relation: .greaterThanOrEqual)
        playbackControlViewContainer.autoPinEdge(toSuperviewEdge: .left)
        playbackControlViewContainer.autoPinEdge(toSuperviewEdge: .right)
        playbackControlViewContainer.autoPinEdge(.top, to: .bottom, of: self.coverView, withOffset: self.padding)
        playbackControlViewContainer.autoPinEdge(.bottom, to: .top, of: self.toolbar, withOffset: -self.padding * 2)

        let seekBarContainerView = UIView()
        seekBarContainerView.isAccessibilityElement = false
        self.view.addSubview(seekBarContainerView)

        seekBarContainerView.autoSetDimension(.height, toSize: 100.0)
        seekBarContainerView.autoPinEdge(.top, to: .bottom, of: self.chapterInfoStack, withOffset: self.padding)
        seekBarContainerView.autoPinEdge(.bottom, to: .top, of: self.coverView, withOffset: -self.padding)
        seekBarContainerView.autoPinEdge(toSuperviewEdge: .leading)
        seekBarContainerView.autoPinEdge(toSuperviewEdge: .trailing)

        seekBarContainerView.addSubview(self.seekBar)
        self.seekBar.delegate = self;
        self.seekBar.isUserInteractionEnabled = false
        self.seekBar.autoCenterInSuperview()
        self.seekBar.autoPinEdge(toSuperviewEdge: .leading, withInset: self.padding * 2, relation: .greaterThanOrEqual)
        self.seekBar.autoPinEdge(toSuperviewEdge: .trailing, withInset: self.padding * 2, relation: .greaterThanOrEqual)
        
        NSLayoutConstraint.autoSetPriority(.defaultHigh) {
            self.coverView.autoMatch(.width, to: .height, of: self.coverView, withMultiplier: 1)
            self.chapterInfoStack.autoSetDimension(.height, toSize: 50)
            playbackControlViewContainer.autoSetDimension(.height, toSize: 100.0)
            self.seekBar.autoSetDimension(.width, toSize: 500)
            self.seekBar.autoPinEdge(.top, to: .bottom, of: self.chapterInfoStack, withOffset: self.padding * 6)
        }

        compactWidthConstraints = NSLayoutConstraint.autoCreateConstraintsWithoutInstalling {
            self.coverView.autoAlignAxis(toSuperviewAxis: .vertical)
            self.chapterInfoStack.autoPinEdge(.top, to: .bottom, of: self.audiobookProgressView, withOffset: self.padding)
            self.chapterInfoStack.autoSetDimension(.height, toSize: 60.0, relation: .lessThanOrEqual)
        }

        regularWidthConstraints = NSLayoutConstraint.autoCreateConstraintsWithoutInstalling {
            self.coverView.autoCenterInSuperview()
            self.coverView.autoSetDimension(.width, toSize: 500.0)
            self.chapterInfoStack.autoPinEdge(.top, to: .bottom, of: self.audiobookProgressView, withOffset: self.padding, relation: .greaterThanOrEqual)
        }

        let chapter = ChapterLocation(
            number: 0,
            part: 0,
            duration: 4000,
            startOffset: 0,
            playheadOffset: 0,
            title: "test title",
            audiobookID: "12345")

        self.toolbar.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: 0)
        self.toolbar.autoPinEdge(.left, to: .left, of: self.view)
        self.toolbar.autoPinEdge(.right, to: .right, of: self.view)
        self.toolbar.autoSetDimension(.height, toSize: self.toolbarHeight)
        let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        var items: [UIBarButtonItem] = [flexibleSpace, flexibleSpace, flexibleSpace, flexibleSpace, flexibleSpace]
        var playbackSpeedText = HumanReadablePlaybackRate(rate: self.audiobookManager.audiobook.player.playbackRate).value
        if self.audiobookManager.audiobook.player.playbackRate == .normalTime {
            playbackSpeedText = NSLocalizedString("1.0×",
                                                  bundle: Bundle.audiobookToolkit()!,
                                                  value: "1.0×",
                                                  comment: "Default title to explain that button changes the speed of playback.")
        }
        let speed =  UIBarButtonItem(
            title: playbackSpeedText,
            style: .plain,
            target: self,
            action: #selector(AudiobookPlayerViewController.speedWasPressed(_:))
        )
        speed.width = toolbarButtonWidth
        let playbackButtonName = DisplayStrings.playbackSpeed
        let playbackRateDescription = HumanReadablePlaybackRate(rate: self.audiobookManager.audiobook.player.playbackRate).accessibleDescription
        speed.accessibilityLabel = "\(playbackButtonName): \(DisplayStrings.currently) \(playbackRateDescription)"
        items.insert(speed, at: self.speedBarButtonIndex)

        let audioRoutingItem = self.audioRoutingBarButtonItem()
        items.insert(audioRoutingItem, at: self.audioRoutingBarButtonIndex)
        let texts = self.sleepTimerTextFor(sleepTimer: self.audiobookManager.sleepTimer, chapter: chapter)
        let sleepTimer = UIBarButtonItem(
            title: texts.title,
            style: .plain,
            target: self,
            action: #selector(AudiobookPlayerViewController.sleepTimerWasPressed(_:))
        )
        sleepTimer.width = toolbarButtonWidth
        sleepTimer.accessibilityLabel = texts.accessibilityLabel

        items.insert(sleepTimer, at: self.sleepTimerBarButtonIndex)
        items.insert(self.bookmarkButton, at: self.addBookmarBarButtonindex)
        
        self.toolbar.setItems(items, animated: true)
        self.seekBar.setOffset(
            chapter.actualOffset,
            duration: chapter.duration,
            timeLeftInBook: self.timeLeftAfter(chapter: chapter),
            middleText: self.middleTextFor(chapter: chapter)
        )

        enableConstraints() // iOS < 13 used to guarantee `traitCollectionDidChange` was called, but not anymore
    }
  
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.gradient.frame = self.view.bounds
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.audiobookManager.timerDelegate = self

        if self.audiobookManager.audiobook.player.isPlaying {
            self.playbackControlView.showPauseButtonIfNeeded()
            self.waitingForPlayer = false
        } else if self.shouldBeginToAutoPlay {
            self.audiobookManager.audiobook.player.play()
            self.shouldBeginToAutoPlay = false
        }

        self.updateSpeedButtonIfNeeded()
        self.updateUI()
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.audiobookManager.saveLocation()
        self.audiobookManager.timerDelegate = nil
        self.dismissToast()
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        enableConstraints()
    }

    //MARK:-

    func enableConstraints() {
        if traitCollection.horizontalSizeClass == .regular {
            if compactWidthConstraints.count > 0 && compactWidthConstraints[0].isActive {
                NSLayoutConstraint.deactivate(compactWidthConstraints)
            }
            NSLayoutConstraint.activate(regularWidthConstraints)
        } else {
            if regularWidthConstraints.count > 0 && regularWidthConstraints[0].isActive {
                NSLayoutConstraint.deactivate(regularWidthConstraints)
            }
            NSLayoutConstraint.activate(compactWidthConstraints)
        }
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

            if element.chapter.inSameChapter(other: self.currentChapterLocation) {
                newResult = timeLeftInChapter
                addUpStuff = true
            }
            return newResult
        })
        return timeLeftAfterChapter
    }

    @objc public func tocWasPressed(_ sender: Any) {
        let bookmarkDataSource = BookmarkDataSource(
            player: self.audiobookManager.audiobook.player,
            audiobookManager: audiobookManager
        )
        let tocVC = AudiobookTableOfContentsTableViewController(
            tableOfContents: self.audiobookManager.tableOfContents,
            bookmarkDataSource: bookmarkDataSource, delegate: self
        )
        navigationItem.backButtonTitle = Strings.Generic.back
        self.navigationController?.pushViewController(tocVC, animated: true)
    }
    
    @objc public func speedWasPressed(_ sender: Any) {
        func actionFrom(rate: PlaybackRate, player: Player) -> UIAlertAction {
            let handler = { (_ action: UIAlertAction) -> Void in
                player.playbackRate = rate
                self.updateSpeedButtonIfNeeded(rate: rate)
            }
            let title = HumanReadablePlaybackRate(rate: rate).value
            let action = UIAlertAction(title: title, style: .default, handler: handler)
            action.accessibilityLabel = HumanReadablePlaybackRate(rate: rate).accessibleDescription
            return action
        }
        
        let actionSheetTitle = DisplayStrings.playbackSpeed

        let actionSheet: UIAlertController
        if self.traitCollection.horizontalSizeClass == .regular && UIAccessibility.isVoiceOverRunning {
            actionSheet = UIAlertController(title: actionSheetTitle, message: nil, preferredStyle: .alert)
        } else {
            actionSheet = UIAlertController(title: actionSheetTitle, message: nil, preferredStyle: .actionSheet)
        }

        let triggers: [PlaybackRate] = [.threeQuartersTime, .normalTime, .oneAndAQuarterTime, .oneAndAHalfTime, .doubleTime ]
        triggers.forEach { (trigger)  in
            let alert = actionFrom(rate: trigger, player: self.audiobookManager.audiobook.player)
            actionSheet.addAction(alert)
        }
        let cancelActionTitle = DisplayStrings.cancel
        actionSheet.addAction(UIAlertAction(title: cancelActionTitle, style: .cancel, handler: nil))
        actionSheet.popoverPresentationController?.barButtonItem = self.toolbar.items?[self.speedBarButtonIndex]
        actionSheet.popoverPresentationController?.sourceView = self.view
        self.present(actionSheet, animated: true, completion: nil)
    }

    private func updateSleepTimerIfNeeded() {
        if let barButtonItem = self.toolbar.items?[self.sleepTimerBarButtonIndex],
        let chapter = self.currentChapterLocation {
            let texts = self.sleepTimerTextFor(sleepTimer: self.audiobookManager.sleepTimer, chapter: chapter)
            barButtonItem.width = toolbarButtonWidth
            barButtonItem.title = texts.title
            barButtonItem.accessibilityLabel = texts.accessibilityLabel
        }
    }

    private func updateSpeedButtonIfNeeded(rate: PlaybackRate? = nil) {
        let rate = rate ?? self.audiobookManager.audiobook.player.playbackRate
        var buttonTitle = HumanReadablePlaybackRate(rate: rate).value
        guard let buttonItem = self.toolbar.items?[self.speedBarButtonIndex],
        buttonItem.title != buttonTitle else {
            return
        }

        if rate == .normalTime {
            buttonTitle = NSLocalizedString("1.0×",
                                            bundle: Bundle.audiobookToolkit()!,
                                            value: "1.0×",
                                            comment: "Default title to explain that button changes the speed of playback.")
        }
        buttonItem.width = toolbarButtonWidth
        buttonItem.title = buttonTitle
        buttonItem.accessibilityLabel = HumanReadablePlaybackRate(rate: rate).accessibleDescription
    }

    @objc public func sleepTimerWasPressed(_ sender: Any) {
        func actionFrom(trigger: SleepTimerTriggerAt, sleepTimer: SleepTimer) -> UIAlertAction {
            let handler = { (_ action: UIAlertAction) -> Void in
                sleepTimer.setTimerTo(trigger: trigger)
                self.updateSleepTimerIfNeeded()
            }
            var action: UIAlertAction! = nil
            switch trigger {
            case .endOfChapter:
                let title = DisplayStrings.endOfChapter
                action = UIAlertAction(title: title, style: .default, handler: handler)
            case .oneHour:
                let title = DisplayStrings.oneHour
                action = UIAlertAction(title: title, style: .default, handler: handler)
            case .thirtyMinutes:
                let title = DisplayStrings.thirtyMinutes
                action = UIAlertAction(title: title, style: .default, handler: handler)
            case .fifteenMinutes:
                let title = DisplayStrings.fifteenMinutes
                action = UIAlertAction(title: title, style: .default, handler: handler)
            case .never:
                let title = DisplayStrings.off
                action = UIAlertAction(title: title, style: .default, handler: handler)
            }
            return action
        }
        let title = DisplayStrings.sleepTimer

        let actionSheet: UIAlertController
        if self.traitCollection.horizontalSizeClass == .regular && UIAccessibility.isVoiceOverRunning {
            actionSheet = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        } else {
            actionSheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        }

        let triggers: [SleepTimerTriggerAt] = [.never, .fifteenMinutes, .thirtyMinutes, .oneHour, .endOfChapter]
        triggers.forEach { (trigger)  in
            let alert = actionFrom(trigger: trigger, sleepTimer: self.audiobookManager.sleepTimer)
            actionSheet.addAction(alert)
        }
        let cancelActionTitle = DisplayStrings.cancel
        actionSheet.addAction(UIAlertAction(title: cancelActionTitle, style: .cancel, handler: nil))
        actionSheet.popoverPresentationController?.barButtonItem = self.toolbar.items?[self.sleepTimerBarButtonIndex]
        actionSheet.popoverPresentationController?.sourceView = self.view
        self.present(actionSheet, animated: true, completion: nil)
    }

    func audioRoutingBarButtonItem() -> UIBarButtonItem {
        let view: UIView
        if #available(iOS 11.0, *) {
            view = AVRoutePickerView()
        } else {
            let volumeView = MPVolumeView()
            volumeView.showsVolumeSlider = false
            volumeView.showsRouteButton = true
            // Set tint of route button: https://stackoverflow.com/a/33016391
            for view in volumeView.subviews {
                if view.isKind(of: UIButton.self) {
                    let buttonOnVolumeView = view as! UIButton
                    volumeView.setRouteButtonImage(buttonOnVolumeView.currentImage?.withRenderingMode(.alwaysTemplate), for: .normal)
                    break
                }
            }
            volumeView.sizeToFit()
            view = volumeView
        }
        let buttonItem = UIBarButtonItem(customView: view)
        buttonItem.width = audioRouteButtonWidth
        buttonItem.isAccessibilityElement = true
        buttonItem.accessibilityLabel = DisplayStrings.playbackDestination
        buttonItem.accessibilityHint = DisplayStrings.destinationAvailabilityAccessiblityHint
        buttonItem.accessibilityTraits = UIAccessibilityTraits.button
        return buttonItem
    }

    @objc func addBookmark() {
        self.audiobookManager.saveBookmark { [weak self] error in
            if let error = error {
                self?.showToast((error as? BookmarkError)?.localizedDescription ?? "")
            } else {
                self?.showToast(DisplayStrings.bookmarkAdded)
            }
        }
    }
    
    private var toastView: UIView?
    private func showToast(_ message: String) {
        Task {
            await asyncDismissToast()

            toastView = UIView()
            toastView!.backgroundColor = UIColor.darkGray
            toastView!.layer.cornerRadius = 10
            toastView!.clipsToBounds = true
            toastView!.alpha = 1.0
            
            let textLabel = UILabel()
            textLabel.textColor = UIColor.white
            textLabel.font = UIFont.systemFont(ofSize: 14.0)
            textLabel.text = message
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.numberOfLines = 0
            textLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            textLabel.setContentHuggingPriority(.required, for: .vertical)
            
            let closeButton = UIButton()
            closeButton.setImage(UIImage(systemName: "xmark.circle"), for: .normal)
            closeButton.tintColor = .white
            closeButton.addTarget(self, action: #selector(dismissToast), for: .touchUpInside)
            
            toastView!.addSubview(textLabel)
            toastView!.addSubview(closeButton)
            self.view.addSubview(toastView!)
            
            toastView!.translatesAutoresizingMaskIntoConstraints = false
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            
            NSLayoutConstraint.activate([
                toastView!.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                toastView!.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
                toastView!.widthAnchor.constraint(equalToConstant: self.view.frame.width * 0.85),
                toastView!.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -75),
                
                textLabel.leadingAnchor.constraint(equalTo: toastView!.leadingAnchor, constant: 10),
                textLabel.topAnchor.constraint(equalTo: toastView!.topAnchor, constant: 10),
                textLabel.bottomAnchor.constraint(equalTo: toastView!.bottomAnchor, constant: -10),
                
                closeButton.centerYAnchor.constraint(equalTo: textLabel.centerYAnchor),
                closeButton.leadingAnchor.constraint(equalTo: textLabel.trailingAnchor, constant: 10),
                closeButton.trailingAnchor.constraint(equalTo: toastView!.trailingAnchor, constant: -10)
            ])
        }
    }
    
    @objc func dismissToast() {
        Task {
            dismissToast(nil)
        }
    }

    func asyncDismissToast() async {
        await withUnsafeContinuation { continuation in
            dismissToast {
                continuation.resume()
            }
        }
    }

    func dismissToast(_ completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            UIView.animate(
                withDuration: 0.4,
                delay: 0.1,
                options: .curveEaseOut,
                animations: {
                    self.toastView?.alpha = 0.0
                }, completion: { _ in
                    self.toastView?.removeFromSuperview()
                    self.toastView = nil
                    completion?()
                }
            )
        }
    }

    func updateUI() {
        guard let currentLocation = self.currentChapterLocation else {
            return
        }
        if !(self.seekBar.scrubbing || self.waitingForPlayer) {

            let timeLeftInBook = self.timeLeftAfter(chapter: currentLocation)
            self.seekBar.setOffset(
                currentLocation.actualOffset,
                duration: currentLocation.duration,
                timeLeftInBook: timeLeftInBook,
                middleText: self.middleTextFor(chapter: currentLocation)
            )
            if let barButtonItem = self.toolbar.items?[self.sleepTimerBarButtonIndex] {
                let texts = self.sleepTimerTextFor(sleepTimer: self.audiobookManager.sleepTimer, chapter: currentLocation)
                barButtonItem.title = texts.title
                barButtonItem.accessibilityLabel = texts.accessibilityLabel
            }
            self.updateSpeedButtonIfNeeded()
            self.updatePlayPauseButtonIfNeeded()
        }

        guard currentLocation.timeRemaining >= 0 else {
            (self.audiobookManager.audiobook.player as? LCPPlayer)?.advanceToNextPlayerItem()
            return
        }
    }

    private func updatePlayPauseButtonIfNeeded() {
        if self.audiobookManager.audiobook.player.isPlaying {
            self.playbackControlView.showPauseButtonIfNeeded()
        } else {
            self.playbackControlView.showPlayButtonIfNeeded()
            if activityIndicator.isAnimating {
                activityIndicator.stopAnimating()
            }
        }
    }

    func sleepTimerTextFor(sleepTimer: SleepTimer, chapter: ChapterLocation) -> (title: String, accessibilityLabel: String) {
        let title: String
        let accessibilityLabel: String
        if sleepTimer.isActive {
            title = HumanReadableTimestamp(timeInterval: sleepTimer.timeRemaining).timecode
            let voiceOverTimeRemaining = VoiceOverTimestamp(
                timeInterval: sleepTimer.timeRemaining
            ).value
            let middleTextFormat = DisplayStrings.timeToPause
            accessibilityLabel = String(format: middleTextFormat, voiceOverTimeRemaining)
        } else {
            title = self.sleepTimerDefaultText
            accessibilityLabel = self.sleepTimerDefaultAccessibilityLabel
        }
        return (title: title, accessibilityLabel: accessibilityLabel)
    }

    func middleTextFor(chapter: ChapterLocation) -> String {
        let defaultTitleFormat = DisplayStrings.trackAt
        let indexString = oneBasedSpineIndex() ?? "--"
        return chapter.title ?? String(format: defaultTitleFormat, indexString)
    }

    func playbackSpeedTextFor(speedText: String) -> String {
        let speedAccessibilityFormatString = DisplayStrings.playbackSpeed
        return String(format: speedAccessibilityFormatString, speedText)
    }

    private func oneBasedSpineIndex() -> String? {
        if let currentChapter = self.currentChapterLocation {
            let spine = self.audiobookManager.audiobook.spine
            for index in 0..<spine.count {
                if currentChapter.inSameChapter(other: spine[index].chapter) {
                    return String(index + 1)
                }
            }
        }
        return nil
    }

    fileprivate func presentAlertAndLog(error: NSError?) {

        let genericTitle = DisplayStrings.problemHasOccurred
        var errorTitle = genericTitle
        var errorDescription = DisplayStrings.tryAgain
        if let error = error {
            if error.domain == OpenAccessPlayerErrorDomain {
                if let openAccessPlayerError = OpenAccessPlayerError.init(rawValue: error.code) {
                    errorTitle = openAccessPlayerError.errorTitle()
                    errorDescription = openAccessPlayerError.errorDescription()
                }
            } else if error.domain == OverdrivePlayerErrorDomain {
                if let overdrivePlayerError = OverdrivePlayerError.init(rawValue: error.code) {
                    errorTitle = overdrivePlayerError.errorTitle()
                    errorDescription = overdrivePlayerError.errorDescription()
                }
            } else {
                errorDescription = error.localizedDescription
            }
        }

        let alertController = UIAlertController(title: errorTitle, message: errorDescription, preferredStyle: .alert)
        let okLocalizedText = DisplayStrings.ok

        let alertAction = UIAlertAction(title: okLocalizedText, style: .default) { _ in
            self.waitingForPlayer = false
        }
        alertController.addAction(alertAction)

        DispatchQueue.main.async {
            self.present(alertController, animated: true)
        }

        let bookID = self.audiobookManager.audiobook.uniqueIdentifier
        let logString = "\(#file): Player reported an error. Audiobook: \(bookID)"
        ATLog(.error, logString, error: error)
    }
}

extension AudiobookPlayerViewController: AudiobookTableOfContentsTableViewControllerDelegate {
    public func userSelected(location: ChapterLocation) {
        
        self.waitingForPlayer = true
        self.activityIndicator.startAnimating()
        
        self.playbackControlView.showPauseButtonIfNeeded()
        
        let timeLeftInBook = self.timeLeftAfter(chapter: location)
        self.seekBar.setOffset(
            location.actualOffset,
            duration: location.duration,
            timeLeftInBook: timeLeftInBook,
            middleText: self.middleTextFor(chapter: location)
        )
        
        if self.audiobookManager.audiobook.player.isPlaying {
            self.shouldBeginToAutoPlay = true
        } else {
            self.shouldBeginToAutoPlay = false
        }
        
        self.audiobookManager.saveLocation()
        self.navigationController?.popViewController(animated: true)
    }
}

extension AudiobookPlayerViewController: AudiobookManagerTimerDelegate {
    public func audiobookManager(_ audiobookManager: AudiobookManager, didUpdate timer: Timer?) {
        self.updateUI()
    }
}

extension AudiobookPlayerViewController: PlaybackControlViewDelegate {
    func playbackControlViewSkipBackButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        guard !waitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else { return }

        self.waitingForPlayer = true
        if self.audiobookManager.audiobook.player.isPlaying {
            self.activityIndicator.startAnimating()
        }

        self.audiobookManager.audiobook.player.skipPlayhead(-SkipTimeInterval) { adjustedLocation in
            self.seekBar.setOffset(adjustedLocation.actualOffset,
                                   duration: adjustedLocation.duration,
                                   timeLeftInBook: self.timeLeftAfter(chapter: adjustedLocation),
                                   middleText: self.middleTextFor(chapter: adjustedLocation)
            )
            self.audiobookManager.saveLocation()
        }
    }
    
    func playbackControlViewSkipForwardButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        guard !waitingForPlayer || self.audiobookManager.audiobook.player.queuesEvents else { return }

        self.waitingForPlayer = true
        if self.audiobookManager.audiobook.player.isPlaying {
            self.activityIndicator.startAnimating()
        }

        self.audiobookManager.audiobook.player.skipPlayhead(SkipTimeInterval) { adjustedLocation in
            self.seekBar.setOffset(adjustedLocation.actualOffset,
                                   duration: adjustedLocation.duration,
                                   timeLeftInBook: self.timeLeftAfter(chapter: adjustedLocation),
                                   middleText: self.middleTextFor(chapter: adjustedLocation)
            )
            self.audiobookManager.saveLocation()
        }
    }

    func playbackControlViewPlayButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        self.waitingForPlayer = true
        self.activityIndicator.startAnimating()
        self.audiobookManager.audiobook.player.play()
        self.audiobookManager.saveLocation()
    }

    func playbackControlViewPauseButtonWasTapped(_ playbackControlView: PlaybackControlView) {
        self.waitingForPlayer = true
        self.activityIndicator.startAnimating()
        self.audiobookManager.audiobook.player.pause()
        self.audiobookManager.saveLocation()
    }
}

extension AudiobookPlayerViewController: PlayerDelegate {
    public func player(_ player: Player, didBeginPlaybackOf chapter: ChapterLocation) {
        self.waitingForPlayer = false
        self.updatePlayPauseButtonIfNeeded()
        if !self.seekBar.isUserInteractionEnabled {
            self.seekBar.isUserInteractionEnabled = true
        }
    }

    public func player(_ player: Player, didStopPlaybackOf chapter: ChapterLocation) {
        self.waitingForPlayer = false
        self.updatePlayPauseButtonIfNeeded()
    }

    public func player(_ player: Player, didFailPlaybackOf chapter: ChapterLocation, withError error: NSError?) {
        presentAlertAndLog(error: error)
    }

    public func player(_ player: Player, didComplete chapter: ChapterLocation) {
        self.waitingForPlayer = false
    }

    public func playerDidUnload(_ player: Player) { }
}

extension AudiobookPlayerViewController: AudiobookNetworkServiceDelegate {
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didCompleteDownloadFor spineElement: SpineElement) {}
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didUpdateProgressFor spineElement: SpineElement) {}
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didDeleteFileFor spineElement: SpineElement) {}
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didReceive error: NSError?, for spineElement: SpineElement) {
        if let error = error,
          error.domain == OverdrivePlayerErrorDomain && error.code == OverdrivePlayerError.downloadExpired.rawValue {
            self.audiobookManager.refreshDelegate?.audiobookManagerDidRequestRefresh()
        }
    }
    public func audiobookNetworkService(_ audiobookNetworkService: AudiobookNetworkService, didUpdateOverallDownloadProgress progress: Float) {
        if (progress < 1.0) && (self.audiobookProgressView.isHidden) {
            self.audiobookProgressView.beginShowingProgress()
        } else if (Int(progress) == 1) && (!self.audiobookProgressView.isHidden) {
            self.audiobookProgressView.stopShowingProgress()
        }
        self.audiobookProgressView.updateProgress(progress)
    }
}

extension AudiobookPlayerViewController: ScrubberViewDelegate {
    func scrubberView(_ scrubberView: ScrubberView, didRequestScrubTo offset: TimeInterval) {
        guard let requestedOffset = self.currentChapterLocation?.update(playheadOffset: offset),
        let currentOffset = self.currentChapterLocation else {
            ATLog(.error, "Scrubber attempted to scrub without a current chapter.")
            return
        }

        self.waitingForPlayer = true
        if self.audiobookManager.audiobook.player.isPlaying {
            self.activityIndicator.startAnimating()
        }

        let offsetMovement = requestedOffset.playheadOffset - currentOffset.actualOffset

        self.audiobookManager.audiobook.player.skipPlayhead(offsetMovement) { adjustedLocation in
            self.seekBar.setOffset(adjustedLocation.actualOffset,
                                   duration: adjustedLocation.duration,
                                   timeLeftInBook: self.timeLeftAfter(chapter: adjustedLocation),
                                   middleText: self.middleTextFor(chapter: adjustedLocation)
            )

            self.audiobookManager.saveLocation()
        }
     }

    func scrubberViewDidRequestAccessibilityIncrement(_ scrubberView: ScrubberView) {
        self.audiobookManager.audiobook.player.skipPlayhead(SkipTimeInterval, completion: nil)
    }

    func scrubberViewDidRequestAccessibilityDecrement(_ scrubberView: ScrubberView) {
        self.audiobookManager.audiobook.player.skipPlayhead(-SkipTimeInterval, completion: nil)
    }
}

