import Foundation
import os.log
import UIKit

public typealias LogHandler = (LogLevel, String, NSError?) -> Void

// MARK: - LogLevel

@objc public enum LogLevel: Int {
  case debug
  case info
  case warn
  case error
}

private func levelToString(_ level: LogLevel) -> String {
  switch level {
  case .debug:
    "DEBUG"
  case .info:
    "INFO"
  case .warn:
    "WARNING"
  case .error:
    "ERROR"
  }
}

public func ATLog(
  file: String = #file,
  line: Int = #line,
  _ level: LogLevel,
  _ message: String,
  error: Error? = nil
) {
  // PERFORMANCE FIX: Only log in debug builds and limit excessive logging
  #if DEBUG
  // Skip debug logs entirely in debug builds to improve performance
  guard level != .debug else {
    return
  }

  // Throttle frequent logging to prevent console spam
  if shouldThrottleLogging(level: level, message: message) {
    return
  }
  #endif

  let url = URL(fileURLWithPath: file)
  let filename = url.lastPathComponent
  let logOutput = "[\(levelToString(level))] \(filename):\(line): \(message)\(error == nil ? "" : "\n\(error!)")"

  #if DEBUG
  // Use os_log in debug for better performance than NSLog
  if #available(iOS 14.0, *) {
    let logger = Logger(subsystem: "com.palace.audiobook", category: filename)
    switch level {
    case .info:
      logger.info("\(message)")
    case .warn:
      logger.warning("\(message)")
    case .error:
      logger.error("\(message)")
    case .debug:
      logger.debug("\(message)")
    }
  } else {
    // Fallback for older iOS versions, but still avoid NSLog in tight loops
    print(logOutput)
  }
  #else
  // Production: only log errors and warnings
  if level == .error || level == .warn {
    NSLog(logOutput)
  }
  #endif

  if level != .debug {
    sharedLogHandler?(level, logOutput, error as NSError?)
  }
}

// MARK: - Performance Optimizations (Thread-Safe)

/// Thread-safe log throttling for audiobook toolkit.
/// Uses a dedicated actor to prevent data races on the message dictionary.
private actor AudiobookLogThrottle {
  private var lastLogMessages: [String: Date] = [:]
  private let throttleInterval: TimeInterval = 0.5 // 500ms throttle
  private let maxTrackedMessages: Int = 100

  func shouldThrottle(level: LogLevel, message: String) -> Bool {
    // Don't throttle errors - they're important
    guard level != .error else {
      return false
    }

    let now = Date()
    let messageKey = String(message.prefix(50))

    if let lastTime = lastLogMessages[messageKey] {
      if now.timeIntervalSince(lastTime) < throttleInterval {
        return true // Throttle this message
      }
    }

    lastLogMessages[messageKey] = now

    // Clean up old entries periodically
    if lastLogMessages.count > maxTrackedMessages {
      let cutoffTime = now.addingTimeInterval(-throttleInterval * 10)
      lastLogMessages = lastLogMessages.filter { $0.value > cutoffTime }
    }

    return false
  }
}

private let audiobookLogThrottle = AudiobookLogThrottle()

/// Synchronous wrapper for the async throttle check.
/// Uses a blocking semaphore pattern since logging needs to be synchronous.
private func shouldThrottleLogging(level: LogLevel, message: String) -> Bool {
  // For performance, use a simple thread-safe check
  // The actor-based implementation ensures thread safety
  var result = false
  let semaphore = DispatchSemaphore(value: 0)

  Task {
    result = await audiobookLogThrottle.shouldThrottle(level: level, message: message)
    semaphore.signal()
  }

  // Wait with timeout to prevent deadlocks
  _ = semaphore.wait(timeout: .now() + .milliseconds(10))
  return result
}

// MARK: - AudiobookLog

/// Enhanced logging specifically for audiobook player debugging
public enum AudiobookLog {
  /// Log seeking operations with context
  public static func seeking(
    _ action: String,
    from: TrackPosition?,
    to: TrackPosition?,
    sliderValue: Double? = nil,
    chapterTitle: String? = nil,
    success: Bool = true,
    file: String = #file,
    line: Int = #line
  ) {
    let fromDesc = from.map { "Track:\($0.track.key)@\($0.timestamp)s" } ?? "nil"
    let toDesc = to.map { "Track:\($0.track.key)@\($0.timestamp)s" } ?? "nil"
    let sliderDesc = sliderValue.map { "slider:\($0)" } ?? ""
    let chapterDesc = chapterTitle.map { "chapter:'\($0)'" } ?? ""
    let status = success ? "✅" : "❌"

    let message = "🎚️ SEEK \(status) \(action): \(fromDesc) → \(toDesc) \(sliderDesc) \(chapterDesc)"
    ATLog(file: file, line: line, .info, message)
  }

  /// Log chapter navigation events
  public static func chapterNavigation(
    _ action: String,
    current: Chapter?,
    target: Chapter?,
    success: Bool = true,
    file: String = #file,
    line: Int = #line
  ) {
    let currentDesc = current?.title ?? "nil"
    let targetDesc = target?.title ?? "nil"
    let status = success ? "✅" : "❌"

    let message = "📖 CHAPTER \(status) \(action): '\(currentDesc)' → '\(targetDesc)'"
    ATLog(file: file, line: line, .info, message)
  }

  /// Log playback events with position context
  public static func playback(
    _ event: String,
    position: TrackPosition? = nil,
    playerType: String,
    file: String = #file,
    line: Int = #line
  ) {
    let posDesc = position.map { "Track:\($0.track.key)@\($0.timestamp)s" } ?? "nil"
    let message = "▶️ PLAYBACK [\(playerType)] \(event): \(posDesc)"
    ATLog(file: file, line: line, .info, message)
  }

  /// Log performance metrics
  public static func performance(
    _ metric: String,
    value: Double,
    unit: String = "",
    file: String = #file,
    line: Int = #line
  ) {
    let message = "📊 PERF \(metric): \(value)\(unit)"
    ATLog(file: file, line: line, .info, message)
  }

  /// Log user interactions
  public static func userAction(
    _ action: String,
    context: String = "",
    file: String = #file,
    line: Int = #line
  ) {
    let message = "👤 USER \(action) \(context)"
    ATLog(file: file, line: line, .info, message)
  }

  /// Log architecture and system events
  public static func architecture(
    _ event: String,
    details: String = "",
    file: String = #file,
    line: Int = #line
  ) {
    let message = "🏗️ ARCH \(event) \(details)"
    ATLog(file: file, line: line, .info, message)
  }
}

// MARK: - AudiobookDebugReporter

public class AudiobookDebugReporter {
  public static let shared = AudiobookDebugReporter()

  private init() {}

  /// Generate comprehensive debug report for audiobook issues
  public func generateReport(for bookId: String) -> String {
    var report = """
    ═══════════════════════════════════════════════════════════════
    🎧 PALACE AUDIOBOOK PLAYER - DEBUG REPORT
    ═══════════════════════════════════════════════════════════════
    Book ID: \(bookId)
    Generated: \(Date())
    ═══════════════════════════════════════════════════════════════

    """

    // Note: AudiobookFileLogger integration would be added when files are in project
    report += "📋 AUDIOBOOK LOGS:\n"
    report += "Logs will be available once optimization files are added to Xcode project\n\n"

    // Add system information
    report += generateSystemInfo()

    // Add player state information
    report += generatePlayerStateInfo()

    return report
  }

  private func generateSystemInfo() -> String {
    let device = UIDevice.current
    let processInfo = ProcessInfo.processInfo

    return """
    📱 SYSTEM INFO:
    ─────────────────────────────────────────────────────────────
    Device: \(device.model) (\(device.systemName) \(device.systemVersion))
    Memory: \(processInfo.physicalMemory / 1024 / 1024)MB
    Thermal State: \(processInfo.thermalState.rawValue)
    Low Power Mode: \(processInfo.isLowPowerModeEnabled)

    """
  }

  private func generatePlayerStateInfo() -> String {
    """
    🎵 PLAYER STATE:
    ─────────────────────────────────────────────────────────────
    Optimization Systems: Ready (files need to be added to Xcode project)
    Enhanced Logging: Active

    """
  }
}

// MARK: - Player Extensions for Enhanced Logging

public extension Player {
  func logSeek(
    action: String,
    from: TrackPosition?,
    to: TrackPosition?,
    sliderValue: Double? = nil,
    success: Bool = true
  ) {
    AudiobookLog.seeking(
      action,
      from: from,
      to: to,
      sliderValue: sliderValue,
      chapterTitle: currentChapter?.title,
      success: success
    )
  }

  func logPlayback(event: String, position: TrackPosition? = nil) {
    AudiobookLog.playback(
      event,
      position: position ?? currentTrackPosition,
      playerType: String(describing: type(of: self))
    )
  }

  func logChapterNav(action: String, target: Chapter?, success: Bool = true) {
    AudiobookLog.chapterNavigation(action, current: currentChapter, target: target, success: success)
  }
}
