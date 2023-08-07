//
//  AudiobookPlaybackTrackerDelegate.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// Audiobook playback delegate for playback time tracking.
///
/// Audiobook player calls two functions to track its playback state:
///  - `playbackStarted()` when the player starts playing a track of an audiobook
///  - `playbackStopped()` when playbook is stopeed, e.g., when the player switches between chapters, the user paused the playback, etc.
@objc
public protocol AudiobookPlaybackTrackerDelegate {
    /// Audiobook player stated playing a track.
    func playbackStarted()
    /// Audiobook player paused or stopped playing a track..
    func playbackStopped()
}
