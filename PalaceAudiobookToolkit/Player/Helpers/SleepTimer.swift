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
    case endOfChapter(chapter: Chapter)
}

private enum TimerDurationLeft {
    case timeInterval(timeInterval: TimeInterval)
    case restOfChapter(chapter: Chapter)
}

private enum TimerState {
    case inactive
    case playing(until: TimerStopPoint)
    case paused(with: TimerDurationLeft)
}

@objc public final class SleepTimer: NSObject {
    private let player: Player
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.palaceaudiobooktoolkit.SleepTimer")
    private var timeLeftInChapter: Double { Double((self.player.currentChapter?.duration ?? 0.0) - (self.player.currentTrackPosition?.timestamp ?? 0.0)) + (self.player.currentChapter?.position.timestamp ?? 0.0)}
    
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
    
    public var timeRemaining: TimeInterval {
        return self.queue.sync {
            switch self.timerState {
            case .inactive:
                return TimeInterval()
            case .playing(until: .date(let date)):
                return date.timeIntervalSinceNow
            case .playing(until: .endOfChapter),
                    .paused(with: .restOfChapter):
                return timeLeftInChapter
            case .paused(with: .timeInterval(let timeInterval)):
                return timeInterval
            }
        }
    }
    
    private var timerState: TimerState = .inactive {
        didSet {
            switch self.timerState {
            case .playing(until: .date),
                    .playing(until: .endOfChapter):
                self.scheduleTimer()
            case .inactive,
                    .paused:
                break
            }
        }
    }
    
    private var timerScheduled: Bool = false
    
    public func setTimerTo(trigger: SleepTimerTriggerAt) {
        self.queue.sync {
            self.update(trigger: trigger)
        }
    }
    
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
                .paused:
            break
        case .playing(until: .date(let date)):
            if date.timeIntervalSinceNow > 0 {
                scheduleTimer()
            } else {
                self.goToSleep()
            }
        case .playing(until: .endOfChapter(let chapter)):
            if self.player.currentChapter == chapter {
                if timeLeftInChapter <= 0 {
                    self.goToSleep()
                } else {
                    scheduleTimer()
                }
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
            sleepIn(secondsFromNow: 15)
        case .thirtyMinutes:
            sleepIn(secondsFromNow: minutes(30))
        case .oneHour:
            sleepIn(secondsFromNow: minutes(60))
        case .endOfChapter:
            if let currentChapter = self.player.currentChapter {
                if self.player.isPlaying {
                    self.timerState = .playing(until: .endOfChapter(chapter: currentChapter))
                } else {
                    self.timerState = .paused(with: .restOfChapter(chapter: currentChapter))
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
            case .started(_ ):
                switch self.timerState {
                case .inactive, .playing:
                    break
                case .paused(with: .timeInterval(let timeInterval)):
                    self.timerState = .playing(until: .date(date: Date(timeIntervalSinceNow: timeInterval)))
                case .paused(with: .restOfChapter):
                    if let currentChapter = self.player.currentChapter {
                        self.timerState = .playing(until: .endOfChapter(chapter: currentChapter))
                    }
                }
            case .completed(let chapter):
                if case .playing(until: .endOfChapter(let targetChapter)) = self.timerState, targetChapter == chapter {
                    self.goToSleep()
                }
            case .stopped, .failed, .bookCompleted, .unloaded:
                switch self.timerState {
                case .inactive, .paused:
                    break
                case .playing(until: .date(let date)):
                    self.timerState = .paused(with: .timeInterval(timeInterval: date.timeIntervalSinceNow))
                case .playing(until: .endOfChapter(let chapterToSleepAt)):
                    self.timerState = .paused(with: .restOfChapter(chapter: chapterToSleepAt))
                }
            }
        }
    }
}
