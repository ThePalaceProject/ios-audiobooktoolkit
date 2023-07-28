//
//  AudiobookPlaybackTrackerDelegate.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 03/07/2023.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc
public protocol AudiobookPlaybackTrackerDelegate {
    func playbackStarted()
    func playbackStopped()
}
