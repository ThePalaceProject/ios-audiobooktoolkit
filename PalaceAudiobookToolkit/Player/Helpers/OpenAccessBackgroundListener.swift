//
//  OpenAccessBackgroundListener.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit

/// Handles background URL session events for OpenAccess audiobook downloads.
/// This listener ensures that downloads started in the background are properly
/// reconnected when the app is relaunched by iOS.
public class OpenAccessBackgroundListener: AudiobookLifecycleListener {
  
  /// Identifier prefix used for OpenAccess background download sessions
  private static let sessionIdentifierPrefix = "openAccessBackgroundIdentifier"
  
  public required init() {}
  
  public func didFinishLaunching() {
    ATLog(.debug, "OpenAccessBackgroundListener: App did finish launching")
  }
  
  public func didEnterBackground() {
    ATLog(.debug, "OpenAccessBackgroundListener: App did enter background")
  }
  
  public func willTerminate() {
    ATLog(.debug, "OpenAccessBackgroundListener: App will terminate")
  }
  
  /// Handles background URL session events for OpenAccess downloads.
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
    
    ATLog(.info, "OpenAccessBackgroundListener: Handling background session: \(identifier)")
    
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
    
    // Create a delegate that will handle the completion
    let delegate = BackgroundSessionReconnectDelegate(sessionIdentifier: identifier)
    
    // Creating a session with the same identifier reconnects to the existing background session
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    
    // Store the session so it's not deallocated
    AudiobookSessionManager.shared.storeReconnectedSession(session, forIdentifier: identifier)
    
    ATLog(.debug, "OpenAccessBackgroundListener: Reconnected to background session: \(identifier)")
  }
}

/// Delegate for handling reconnected background session events
final class BackgroundSessionReconnectDelegate: NSObject, URLSessionDelegate, URLSessionDownloadDelegate {
  
  private let sessionIdentifier: String
  
  init(sessionIdentifier: String) {
    self.sessionIdentifier = sessionIdentifier
    super.init()
  }
  
  // MARK: - URLSessionDelegate
  
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    ATLog(.info, "BackgroundSessionReconnectDelegate: Session finished events: \(sessionIdentifier)")
    
    // Call the completion handler that iOS is waiting for
    AudiobookSessionManager.shared.callCompletionHandler(forSessionIdentifier: sessionIdentifier)
  }
  
  // MARK: - URLSessionDownloadDelegate
  
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    ATLog(.info, "BackgroundSessionReconnectDelegate: Download finished to: \(location.path)")
    
    // The download completed while app was in background
    // Move the file to the correct location
    guard let originalURL = downloadTask.originalRequest?.url else {
      ATLog(.error, "BackgroundSessionReconnectDelegate: No original URL for completed download")
      return
    }
    
    // Notify the session manager about the completed download
    AudiobookSessionManager.shared.handleBackgroundDownloadCompletion(
      sessionIdentifier: sessionIdentifier,
      downloadedFileURL: location,
      originalURL: originalURL
    )
  }
  
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      ATLog(.error, "BackgroundSessionReconnectDelegate: Task completed with error: \(error.localizedDescription)")
      AudiobookSessionManager.shared.handleBackgroundDownloadError(
        sessionIdentifier: sessionIdentifier,
        error: error
      )
    } else {
      ATLog(.debug, "BackgroundSessionReconnectDelegate: Task completed successfully")
    }
  }
  
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let progress = totalBytesExpectedToWrite > 0 
      ? Float(totalBytesWritten) / Float(totalBytesExpectedToWrite) 
      : 0.0
    ATLog(.debug, "BackgroundSessionReconnectDelegate: Download progress: \(progress * 100)%")
  }
}
