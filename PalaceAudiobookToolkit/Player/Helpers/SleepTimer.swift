//
//  SleepTimer.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 3/7/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import Combine
import UIKit

// MARK: - SleepTimerTriggerAt

@objc public enum SleepTimerTriggerAt: Int, CaseIterable {
  case never
  case fifteenMinutes
  case thirtyMinutes
  case oneHour
  case endOfChapter
}

// MARK: - TimerStopPoint

private enum TimerStopPoint {
  case date(date: Date)
  case endOfChapter(chapter: Chapter)
}

// MARK: - TimerDurationLeft

private enum TimerDurationLeft {
  case timeInterval(timeInterval: TimeInterval)
  case restOfChapter(chapter: Chapter)
}

// MARK: - TimerState

private enum TimerState {
  case inactive
  case playing(until: TimerStopPoint)
  case paused(with: TimerDurationLeft)
}

// MARK: - SleepTimer

@objc public final class SleepTimer: NSObject {
  private let player: Player
  private var cancellables = Set<AnyCancellable>()
  private let queue = DispatchQueue(label: "com.palaceaudiobooktoolkit.SleepTimer")
  private var timeLeftInChapter: Double {
    guard let duration = player.currentChapter?.duration ?? player.currentTrackPosition?.track.duration else {
      return 0.0
    }

    return Double(duration - player.currentOffset)
  }

  public var isActive: Bool {
    queue.sync {
      switch self.timerState {
      case .inactive:
        false
      case .playing,
           .paused:
        true
      }
    }
  }

  public var timeRemaining: TimeInterval {
    queue.sync {
      switch self.timerState {
      case .inactive:
        TimeInterval()
      case let .playing(until: .date(date)):
        date.timeIntervalSinceNow
      case .playing(until: .endOfChapter),
           .paused(with: .restOfChapter):
        timeLeftInChapter
      case let .paused(with: .timeInterval(timeInterval)):
        timeInterval
      }
    }
  }

  private var timerState: TimerState = .inactive {
    didSet {
      switch timerState {
      case .playing(until: .date),
           .playing(until: .endOfChapter):
        scheduleTimer()
      case .inactive,
           .paused:
        break
      }
    }
  }

  private var timerScheduled: Bool = false

  public func setTimerTo(trigger: SleepTimerTriggerAt) {
    queue.sync {
      self.update(trigger: trigger)
    }
  }

  private func goToSleep() {
    DispatchQueue.main.async { [weak self] () in
      self?.player.pause()
    }
    timerState = .inactive
  }

  private func scheduleTimer() {
    if !timerScheduled {
      timerScheduled = true
      queue.asyncAfter(deadline: DispatchTime.now() + 1) { [weak self] () in
        self?.checkTimerStateAndScheduleNextRun()
      }
    }
  }

  private func checkTimerStateAndScheduleNextRun() {
    timerScheduled = false
    switch timerState {
    case .inactive,
         .paused:
      break
    case let .playing(until: .date(date)):
      if date.timeIntervalSinceNow > 0 {
        scheduleTimer()
      } else {
        goToSleep()
      }
    case let .playing(until: .endOfChapter(chapter)):
      if player.currentChapter == chapter {
        if timeLeftInChapter <= 0 {
          goToSleep()
        } else {
          scheduleTimer()
        }
      } else {
        goToSleep()
      }
    }
  }

  private func update(trigger: SleepTimerTriggerAt) {
    func sleepIn(secondsFromNow: TimeInterval) {
      if player.isPlaying {
        timerState = .playing(until: .date(date: Date(timeIntervalSinceNow: secondsFromNow)))
      } else {
        timerState = .paused(with: .timeInterval(timeInterval: secondsFromNow))
      }
    }

    let minutes: (_ timeInterval: TimeInterval) -> TimeInterval = { $0 * 60 }
    switch trigger {
    case .never:
      timerState = .inactive
    case .fifteenMinutes:
      sleepIn(secondsFromNow: minutes(15))
    case .thirtyMinutes:
      sleepIn(secondsFromNow: minutes(30))
    case .oneHour:
      sleepIn(secondsFromNow: minutes(60))
    case .endOfChapter:
      if let currentChapter = player.currentChapter {
        if player.isPlaying {
          timerState = .playing(until: .endOfChapter(chapter: currentChapter))
        } else {
          timerState = .paused(with: .restOfChapter(chapter: currentChapter))
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
    queue.sync {
      switch playbackState {
      case .started:
        switch self.timerState {
        case .inactive, .playing:
          break
        case let .paused(with: .timeInterval(timeInterval)):
          self.timerState = .playing(until: .date(date: Date(timeIntervalSinceNow: timeInterval)))
        case .paused(with: .restOfChapter):
          if let currentChapter = self.player.currentChapter {
            self.timerState = .playing(until: .endOfChapter(chapter: currentChapter))
          }
        }
      case let .completed(chapter):
        if case let .playing(until: .endOfChapter(targetChapter)) = self.timerState, targetChapter == chapter {
          self.goToSleep()
        }
      case .stopped, .failed, .bookCompleted, .unloaded:
        switch self.timerState {
        case .inactive, .paused:
          break
        case let .playing(until: .date(date)):
          self.timerState = .paused(with: .timeInterval(timeInterval: date.timeIntervalSinceNow))
        case let .playing(until: .endOfChapter(chapterToSleepAt)):
          self.timerState = .paused(with: .restOfChapter(chapter: chapterToSleepAt))
        }
      }
    }
  }
}
