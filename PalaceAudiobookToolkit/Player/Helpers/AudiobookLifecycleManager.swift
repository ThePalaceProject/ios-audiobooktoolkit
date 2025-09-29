//
//  AudiobookLifecycleManager.swift
//  NYPLAudibookKit
//
//  Created by Dean Silfen on 1/12/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import AVFoundation
import UIKit

// MARK: - AudiobookLifecycleListener

@objc public protocol AudiobookLifecycleListener: class {
  func didFinishLaunching()
  func didEnterBackground()
  func willTerminate()
  func handleBackgroundURLSession(for identifier: String, completionHandler: @escaping () -> Void) -> Bool
  init()
}

// MARK: - AudiobookLifecycleManager

/// Hooks into life cycle events for AppDelegate.swift. Listens to notifcations from
/// AudioEngine to ensure other objects know when it is safe to perform operations on
/// their SDK.
@objcMembers public class AudiobookLifecycleManager: NSObject {
  /**
   The shared instance of the lifecycle manager intended for usage throughout the framework.
   */
  public func didFinishLaunching() {
    listeners.forEach { listener in
      listener.didFinishLaunching()
    }
  }

  public func didEnterBackground() {
    listeners.forEach { listener in
      listener.didEnterBackground()
    }
  }

  public func willTerminate() {
    listeners.forEach { listener in
      listener.willTerminate()
    }
  }

  public func handleEventsForBackgroundURLSession(for identifier: String, completionHandler: @escaping () -> Void) {
    for listener in listeners {
      let didHandle = listener.handleBackgroundURLSession(for: identifier, completionHandler: completionHandler)
      if didHandle {
        break
      }
    }
  }

  private var listeners = [AudiobookLifecycleListener]()
  override public init() {
    super.init()
    let findawayListener = FindawayAudiobookLifecycleListener()
    listeners.append(findawayListener)
  }
}
