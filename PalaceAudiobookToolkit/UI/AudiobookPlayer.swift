//
//  AudiobookPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 15/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

@objcMembers
public class AudiobookPlayer: NSObject {
    
    private var model: AudiobookPlaybackModel
    public let viewController: UIViewController
    
    @objc
    public init(audiobookManager: AudiobookManager) {
        self.model = AudiobookPlaybackModel(audiobookManager: audiobookManager)
        self.viewController = UIHostingController(rootView: AudiobookPlayerView(model: model))
        self.viewController.hidesBottomBarWhenPushed = true
        super.init()
    }
    
    @objc
    public func updateImage(_ image: UIImage) {
        self.model.coverImage = image
    }
}
