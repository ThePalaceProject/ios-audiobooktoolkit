//
//  FindawayAudiobookLifecycleListener.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 5/8/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AudioEngine
import UIKit

public class FindawayAudiobookLifecycleListener: AudiobookLifecycleListener {
  public func didFinishLaunching() {
    FAEAudioEngine.shared()?.didFinishLaunching()
  }

  public func didEnterBackground() {
    FAEAudioEngine.shared()?.didEnterBackground()
  }

  public func willTerminate() {
    FAEAudioEngine.shared()?.willTerminate()
  }

  public func handleBackgroundURLSession(for identifier: String, completionHandler: @escaping () -> Void) -> Bool {
    let isHandled: Bool
    if identifier.contains("FWAE") {
      FAEAudioEngine.shared()?.didFinishLaunching()
      FAEAudioEngine.shared()?.downloadEngine?.addCompletionHandler(completionHandler, forSession: identifier)
      isHandled = true
    } else {
      isHandled = false
    }
    return isHandled
  }

  @objc public func audioEngineDatabaseVerificationStatusHasBeenUpdated(_: NSNotification) {
    FindawayDatabaseVerification.shared.verified = true
  }

  public required init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(FindawayAudiobookLifecycleListener.audioEngineDatabaseVerificationStatusHasBeenUpdated(_:)),
      name: NSNotification.Name.FAEDatabaseVerificationComplete,
      object: nil
    )
  }
}
