//
//  OverdriveBackgroundListener.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// Handles background URL session events for OverDrive audiobook downloads.
/// This listener ensures that downloads started in the background are properly
/// reconnected when the app is relaunched by iOS.
public class OverdriveBackgroundListener: AudiobookLifecycleListener {
  
  /// Identifier prefix used for OverDrive background download sessions
  private static let sessionIdentifierPrefix = "overdriveBackgroundIdentifier"
  
  public required init() {}
  
  public func didFinishLaunching() {
    ATLog(.debug, "OverdriveBackgroundListener: App did finish launching")
  }
  
  public func didEnterBackground() {
    ATLog(.debug, "OverdriveBackgroundListener: App did enter background")
  }
  
  public func willTerminate() {
    ATLog(.debug, "OverdriveBackgroundListener: App will terminate")
  }
  
  /// Handles background URL session events for OverDrive downloads.
  /// iOS calls this when a background download completes while the app was suspended/terminated.
  ///
  /// - Parameters:
  ///   - identifier: The background session identifier
  ///   - completionHandler: Must be called when all events have been processed
  /// - Returns: `true` if this listener handled the session, `false` otherwise
  public func handleBackgroundURLSession(for identifier: String, completionHandler: @escaping () -> Void) -> Bool {
    guard identifier.contains(Self.sessionIdentifierPrefix) else {
      return false
    }
    
    ATLog(.info, "OverdriveBackgroundListener: Handling background session: \(identifier)")
    
    // Register the completion handler with the session manager
    AudiobookSessionManager.shared.registerBackgroundCompletionHandler(
      completionHandler,
      forSessionIdentifier: identifier
    )
    
    // Reconnect to the background session to receive delegate callbacks
    reconnectToBackgroundSession(identifier: identifier)
    
    return true
  }
  
  /// Reconnects to an existing background URLSession to receive completion callbacks.
  private func reconnectToBackgroundSession(identifier: String) {
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    
    // Reuse the same delegate class from OpenAccessBackgroundListener
    let delegate = BackgroundSessionReconnectDelegate(sessionIdentifier: identifier)
    
    // Creating a session with the same identifier reconnects to the existing background session
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    
    // Store the session so it's not deallocated
    AudiobookSessionManager.shared.storeReconnectedSession(session, forIdentifier: identifier)
    
    ATLog(.debug, "OverdriveBackgroundListener: Reconnected to background session: \(identifier)")
  }
}
