//
//  MediaControlPublisher.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/4/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Combine
import MediaPlayer

// MARK: - MediaControlCommand

enum MediaControlCommand {
  case playPause
  case skipForward
  case skipBackward
  case changePlaybackRate(Float)
}

// MARK: - MediaControlPublisher

class MediaControlPublisher {
  private(set) var commandPublisher = PassthroughSubject<MediaControlCommand, Never>()
  private let commandCenter = MPRemoteCommandCenter.shared()

  init() {
    setup()
  }

  private func setup() {
    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.skipForwardCommand.isEnabled = true
    commandCenter.skipForwardCommand.preferredIntervals = [30]
    commandCenter.skipBackwardCommand.isEnabled = true
    commandCenter.skipBackwardCommand.preferredIntervals = [30]
    commandCenter.changePlaybackRateCommand.isEnabled = true

    commandCenter.playCommand.addTarget { [unowned self] _ in
      commandPublisher.send(.playPause)
      return .success
    }

    commandCenter.pauseCommand.addTarget { [unowned self] _ in
      commandPublisher.send(.playPause)
      return .success
    }

    commandCenter.togglePlayPauseCommand.addTarget { [unowned self] _ in
      commandPublisher.send(.playPause)
      return .success
    }

    commandCenter.skipForwardCommand.addTarget { [unowned self] _ in
      commandPublisher.send(.skipForward)
      return .success
    }

    commandCenter.skipBackwardCommand.addTarget { [unowned self] _ in
      commandPublisher.send(.skipBackward)
      return .success
    }

    commandCenter.changePlaybackRateCommand.addTarget { [unowned self] event in
      guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else {
        return .commandFailed
      }
      commandPublisher.send(.changePlaybackRate(Float(rateEvent.playbackRate)))
      return .success
    }
  }

  deinit {
    tearDown()
  }

  func tearDown() {
    commandCenter.playCommand.removeTarget(nil)
    commandCenter.pauseCommand.removeTarget(nil)
    commandCenter.togglePlayPauseCommand.removeTarget(nil)
    commandCenter.skipForwardCommand.removeTarget(nil)
    commandCenter.skipBackwardCommand.removeTarget(nil)
    commandCenter.changePlaybackRateCommand.removeTarget(nil)
  }
}
