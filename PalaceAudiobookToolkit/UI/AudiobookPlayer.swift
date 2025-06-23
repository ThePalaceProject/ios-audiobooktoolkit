//
//  AudiobookPlayer.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 15/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine


public class AudiobookPlayer: UIViewController {
    
    private var model: AudiobookPlaybackModel!
    private var cancellables = Set<AnyCancellable>()

    @available(*, unavailable, message: "Use init?(audiobookManager:) instead")
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
        
    public init(audiobookManager: AudiobookManager, coverImagePublisher: AnyPublisher<UIImage?, Never>) {
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

        coverImagePublisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newImage in
                self?.updateImage(newImage)
            }
            .store(in: &cancellables)
    }
    private var playerViewController: UIHostingController<AudiobookPlayerView>? {
        children.first as? UIHostingController<AudiobookPlayerView>
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            tabBarController?.setTabBarHidden(false, animated: true)
        }
        playerViewController?.rootView.unload()
        
        playerViewController?.willMove(toParent: nil)
        playerViewController?.view.removeFromSuperview()
        playerViewController?.removeFromParent()
    }
    
    public func updateImage(_ image: UIImage) {
        playerViewController?.rootView.updateImage(image)
    }
}
