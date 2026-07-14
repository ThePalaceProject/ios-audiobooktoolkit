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

// MARK: - FindawaySupport

/// Whether Findaway's proprietary `AudioEngine` framework is actually present in
/// this process.
///
/// The toolkit weak-links `AudioEngine`, so the same binary runs in builds that
/// embed it (full-DRM Palace) and builds that don't (the open, no-DRM build,
/// which must not ship the proprietary SDK). This mirrors Android's
/// `org.thepalaceproject.findaway.enabled` property (default `false`): where the
/// SDK is absent, every Findaway code path is skipped rather than dyld-faulting
/// on a missing library at launch.
///
/// `FAEAudioEngine` is AudioEngine's Obj-C principal class; `NSClassFromString`
/// resolves it only when the framework is loaded. Evaluated once — the set of
/// loaded frameworks does not change over a process's lifetime.
enum FindawaySupport {
  static let isAvailable: Bool = (NSClassFromString("FAEAudioEngine") != nil)
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
    
    // Register the Findaway lifecycle listener only when the AudioEngine SDK is
    // actually linked into this process. In the open (no-DRM) build AudioEngine
    // is absent, so constructing this listener — which registers for the
    // AudioEngine-defined `FAEDatabaseVerificationComplete` notification — would
    // reference a symbol dyld cannot resolve. Mirrors Android's
    // `findaway.enabled = false` open build.
    #if FEATURE_FINDAWAY
    if FindawaySupport.isAvailable {
      listeners.append(FindawayAudiobookLifecycleListener())
    }
    #endif

    // Register OpenAccess background session listener
    let openAccessListener = OpenAccessBackgroundListener()
    listeners.append(openAccessListener)
    
    // Register OverDrive background session listener
    let overdriveListener = OverdriveBackgroundListener()
    listeners.append(overdriveListener)
    
    ATLog(.debug, "AudiobookLifecycleManager: Registered \(listeners.count) listeners")
  }
}
