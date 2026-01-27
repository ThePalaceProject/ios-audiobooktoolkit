//
//  MediaControlPublisher.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/4/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - MediaControlCommand

enum MediaControlCommand {
  case play
  case pause
  case playPause
  case skipForward
  case skipBackward
  case changePlaybackRate(Float)
}

// MARK: - MediaControlPublisher

/// Publishes media control commands from MPRemoteCommandCenter.
/// 
/// NOTE: This class tracks its own command targets and only removes those on teardown.
/// This allows other components (like PlaybackBootstrapper) to also register targets
/// without being affected by this class's lifecycle.
class MediaControlPublisher {
  private(set) var commandPublisher = PassthroughSubject<MediaControlCommand, Never>()
  private let commandCenter = MPRemoteCommandCenter.shared()
  private var isSetup = false
  
  // Track our own targets so we only remove those (not all targets)
  private var playTarget: Any?
  private var pauseTarget: Any?
  private var toggleTarget: Any?
  private var skipForwardTarget: Any?
  private var skipBackwardTarget: Any?
  private var rateTarget: Any?

  init() {
    setup()
    
    // Re-configure commands when audio session is interrupted/resumed
    // This ensures CarPlay buttons stay correct after app state changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    
    // Re-configure when app becomes active (handles CarPlay reconnection)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }
  
  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }
    
    if type == .ended {
      // Re-apply command configuration after interruption ends
      ATLog(.debug, "MediaControlPublisher: Re-configuring commands after audio interruption")
      configureCommands()
    }
  }
  
  @objc private func handleAppDidBecomeActive() {
    // Re-apply command configuration when app becomes active
    // This ensures CarPlay buttons are correct after backgrounding
    ATLog(.debug, "MediaControlPublisher: Re-configuring commands after app became active")
    configureCommands()
  }

  private func setup() {
    configureCommands()
    addCommandTargets()
    isSetup = true
  }
  
  /// Configures which commands are enabled/disabled.
  /// Can be called multiple times to re-apply configuration.
  private func configureCommands() {
    // Enable audiobook-specific commands
    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.skipForwardCommand.isEnabled = true
    commandCenter.skipForwardCommand.preferredIntervals = [30]
    commandCenter.skipBackwardCommand.isEnabled = true
    commandCenter.skipBackwardCommand.preferredIntervals = [30]
    commandCenter.changePlaybackRateCommand.isEnabled = true
    
    // CRITICAL: Explicitly disable track navigation commands for audiobooks
    // Without this, CarPlay may interpret skip buttons as next/previous track
    // which causes playback to restart instead of skipping 30 seconds
    commandCenter.nextTrackCommand.isEnabled = false
    commandCenter.previousTrackCommand.isEnabled = false
    commandCenter.seekForwardCommand.isEnabled = false
    commandCenter.seekBackwardCommand.isEnabled = false
    commandCenter.changeRepeatModeCommand.isEnabled = false
    commandCenter.changeShuffleModeCommand.isEnabled = false
  }
  
  /// Adds command targets. Should only be called once.
  private func addCommandTargets() {
    playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
      self?.commandPublisher.send(.play)
      return .success
    }

    pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.commandPublisher.send(.pause)
      return .success
    }

    toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.commandPublisher.send(.playPause)
      return .success
    }

    skipForwardTarget = commandCenter.skipForwardCommand.addTarget { [weak self] _ in
      self?.commandPublisher.send(.skipForward)
      return .success
    }

    skipBackwardTarget = commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
      self?.commandPublisher.send(.skipBackward)
      return .success
    }

    rateTarget = commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
      guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
        return .commandFailed
      }
      self?.commandPublisher.send(.changePlaybackRate(Float(rateEvent.playbackRate)))
      return .success
    }
  }

  deinit {
    tearDown()
  }

  func tearDown() {
    NotificationCenter.default.removeObserver(self)
    
    // IMPORTANT: Only remove OUR targets, not all targets
    // This preserves targets registered by other components (e.g., PlaybackBootstrapper)
    if let target = playTarget {
      commandCenter.playCommand.removeTarget(target)
      playTarget = nil
    }
    if let target = pauseTarget {
      commandCenter.pauseCommand.removeTarget(target)
      pauseTarget = nil
    }
    if let target = toggleTarget {
      commandCenter.togglePlayPauseCommand.removeTarget(target)
      toggleTarget = nil
    }
    if let target = skipForwardTarget {
      commandCenter.skipForwardCommand.removeTarget(target)
      skipForwardTarget = nil
    }
    if let target = skipBackwardTarget {
      commandCenter.skipBackwardCommand.removeTarget(target)
      skipBackwardTarget = nil
    }
    if let target = rateTarget {
      commandCenter.changePlaybackRateCommand.removeTarget(target)
      rateTarget = nil
    }
    
    isSetup = false
  }
}
