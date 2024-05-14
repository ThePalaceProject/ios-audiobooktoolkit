//
//  SleepTimer.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 3/7/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit
import Combine

@objc public enum SleepTimerTriggerAt: Int, CaseIterable {
    case never
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case endOfChapter
}

private enum TimerStopPoint {
    case date(date: Date)
    case endOfChapter(trackPosition: TrackPosition)
}

private enum TimerDurationLeft {
    case timeInterval(timeInterval: TimeInterval)
    case restOfChapter(trackPosition: TrackPosition)
}

private enum TimerState {
    case inactive
    case playing(until: TimerStopPoint)
    case paused(with: TimerDurationLeft)
}

/// Class used to schedule timers to automatically pause
/// the current playing audiobook. This class must be retained
/// after the timer has been started in order to properly
/// stop the current playing book.
///
/// All methods should block until they can safely access their
/// properties.
@objc public final class SleepTimer: NSObject {
    private let player: Player
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.palaceaudiobooktoolkit.SleepTimer")
    
    /// Flag to find out if the timer is currently scheduled.
    public var isActive: Bool {
        return self.queue.sync {
            switch self.timerState {
            case .inactive:
                return false
            case .playing,
                 .paused:
                return true
            }
        }
    }

    /// Time remaining until the book will be paused.
    public var timeRemaining: TimeInterval {
        return self.queue.sync {
            switch self.timerState {
            case .inactive:
                return TimeInterval()
            case .playing(until: .date(let date)):
                return date.timeIntervalSinceNow
            case .playing(until: .endOfChapter),
                 .paused(with: .restOfChapter):
                return Double(self.player.currentTrackPosition?.timestamp ?? 0)
            case .paused(with: .timeInterval(let timeInterval)):
                return timeInterval
            }
        }
    }
    
    /// We only want to count down the sleep timer
    /// while content is playing. This value keeps
    /// track of whether the timer "playing" and
    /// should be counting down until it terminates
    /// playback, or if it is "paused" and should
    /// record the time remaining in the timer
    private var timerState: TimerState = .inactive {
        didSet {
            switch self.timerState {
            case .playing(until: .date):
                self.scheduleTimer()
            case .inactive,
                 .paused,
                 .playing(until: .endOfChapter):
                break
            }
        }
    }

    /// The timer should be scheduled whenever we are
    /// in a `self.timerState == .playing(.date(_))`
    /// state. This is handled automatically by the
    /// setter for `timerState`.
    private var timerScheduled: Bool = false

    /// Start a timer for a specific amount of time.
    public func setTimerTo(trigger: SleepTimerTriggerAt) {
        self.queue.sync {
            self.update(trigger: trigger)
        }
    }

    /// Should be called when the sleep timer has hit zero.
    private func goToSleep() {
        DispatchQueue.main.async { [weak self] () in
            self?.player.pause()
        }
        self.timerState = .inactive
    }

    private func scheduleTimer() {
        if !self.timerScheduled {
            self.timerScheduled = true
            self.queue.asyncAfter(deadline: DispatchTime.now() + 1) { [weak self] () in
                self?.checkTimerStateAndScheduleNextRun()
            }
        }
    }

    private func checkTimerStateAndScheduleNextRun() {
        self.timerScheduled = false
        switch self.timerState {
        case .inactive,
             .paused,
             .playing(until: .endOfChapter):
            break
        case .playing(until: .date(let date)):
            if date.timeIntervalSinceNow > 0 {
                scheduleTimer()
            } else {
                self.goToSleep()
            }
        }
    }

    private func update(trigger: SleepTimerTriggerAt) {
        func sleepIn(secondsFromNow: TimeInterval) {
            if self.player.isPlaying {
                self.timerState = .playing(until: .date(date: Date(timeIntervalSinceNow: secondsFromNow)))
            } else {
                self.timerState = .paused(with: .timeInterval(timeInterval: secondsFromNow))
            }
        }

        let minutes: (_ timeInterval: TimeInterval) -> TimeInterval = { $0 * 60 }
        switch trigger {
        case .never:
            self.timerState = .inactive
        case .fifteenMinutes:
            sleepIn(secondsFromNow: minutes(15))
        case .thirtyMinutes:
            sleepIn(secondsFromNow: minutes(30))
        case .oneHour:
            sleepIn(secondsFromNow: minutes(60))
        case .endOfChapter:
            if let currentTrackPosition = self.player.currentTrackPosition {
                if self.player.isPlaying {
                    self.timerState = .playing(until: .endOfChapter(trackPosition: currentTrackPosition))
                } else {
                    self.timerState = .paused(with: .restOfChapter(trackPosition: currentTrackPosition))
                }
            }
        }
    }

    init(player: Player) {
        self.player = player
        super.init()
        subscribeToPlaybackChanges()
    }
    
    private func subscribeToPlaybackChanges() {
        player.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playbackState in
                self?.handlePlaybackState(playbackState)
            }
            .store(in: &cancellables)
    }
}

extension SleepTimer {
    private func handlePlaybackState(_ playbackState: PlaybackState) {
        self.queue.sync {
            switch playbackState {
            case .started(let trackPosition):
                switch self.timerState {
                case .inactive, .playing:
                    break
                case .paused(with: .timeInterval(let timeInterval)):
                    self.timerState = .playing(until: .date(date: Date(timeIntervalSinceNow: timeInterval)))
                case .paused(with: .restOfChapter):
                    self.timerState = .playing(until: .endOfChapter(trackPosition: trackPosition))
                }
            case .stopped, .failed, .completed, .bookCompleted, .unloaded:
                switch self.timerState {
                case .inactive, .paused:
                    break
                case .playing(until: .date(let date)):
                    self.timerState = .paused(with: .timeInterval(timeInterval: date.timeIntervalSinceNow))
                case .playing(until: .endOfChapter(let chapterToSleepAt)):
                    self.timerState = .paused(with: .restOfChapter(trackPosition: chapterToSleepAt))
                }
            }
        }
    }
}


