//
//  AudiobookPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 15/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI


public class AudiobookPlayer: UIViewController {
    
    private var model: AudiobookPlaybackModel!
    
    @available(*, unavailable, message: "Use init?(audiobookManager:) instead")
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
        
    public init(audiobookManager: AudiobookManager) {
        model = AudiobookPlaybackModel(audiobookManager: audiobookManager)
        super.init(nibName: nil, bundle: nil)
        let playerViewController =  UIHostingController(rootView: AudiobookPlayerView(model: model))
        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        playerViewController.view.frame = self.view.bounds
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        playerViewController.didMove(toParent: self)
        hidesBottomBarWhenPushed = true
    }

    private var playerViewController: UIHostingController<AudiobookPlayerView>? {
        children.first as? UIHostingController<AudiobookPlayerView>
    }

    public override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        playerViewController?.rootView.unload()
    }
    
    @objc
    public func updateImage(_ image: UIImage) {
        playerViewController?.rootView.updateImage(image)
    }
}
