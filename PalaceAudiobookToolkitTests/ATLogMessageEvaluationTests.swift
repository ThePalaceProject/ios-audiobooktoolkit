//
//  ATLogMessageEvaluationTests.swift
//  PalaceAudiobookToolkitTests
//
//  `ATLog` builds its message only for a level that some output will use, so
//  per-tick logging such as the Now Playing update costs nothing when discarded.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class ATLogMessageEvaluationTests: XCTestCase {
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _evaluations = 0
    private var _lines: [String] = []
    var evaluations: Int { lock.withLock { _evaluations } }
    var lines: [String] { lock.withLock { _lines } }

    func message(_ text: String) -> String {
      lock.withLock { _evaluations += 1 }
      return text
    }

    func record(_ line: String) {
      lock.withLock { _lines.append(line) }
    }
  }

  private var previousLogHandler: LogHandler?
  private var previousMinimumLevel: LogLevel = .info

  override func setUp() {
    super.setUp()
    previousLogHandler = sharedLogHandler
    previousMinimumLevel = sharedLogHandlerMinimumLevel
  }

  override func tearDown() {
    sharedLogHandler = previousLogHandler
    sharedLogHandlerMinimumLevel = previousMinimumLevel
    super.tearDown()
  }

  /// Test builds are DEBUG builds, where `.debug` is discarded before any output.
  func testATLog_whenLevelIsDisabled_doesNotBuildTheMessage() {
    let recorder = Recorder()
    sharedLogHandler = { _, line, _ in recorder.record(line) }

    ATLog(.debug, recorder.message("discarded \(UUID().uuidString)"))

    XCTAssertEqual(recorder.evaluations, 0, "A discarded level must not build its message")
    XCTAssertEqual(recorder.lines, [])
  }

  /// The handler receives the line in the format callers already parse.
  func testATLog_whenLevelIsEnabled_buildsTheMessageOnceAndForwardsTheSameLine() {
    let recorder = Recorder()
    sharedLogHandler = { _, line, _ in recorder.record(line) }
    let text = "enabled \(UUID().uuidString)"

    let line = #line + 1
    ATLog(.info, recorder.message(text))

    XCTAssertEqual(recorder.evaluations, 1)
    XCTAssertEqual(recorder.lines, ["[INFO] ATLogMessageEvaluationTests.swift:\(line): \(text)"])
  }

  /// An attached error is appended on its own line, as before.
  func testATLog_whenErrorIsAttached_appendsTheErrorToTheLine() {
    let recorder = Recorder()
    sharedLogHandler = { _, line, _ in recorder.record(line) }
    let text = "failed \(UUID().uuidString)"
    let error = NSError(domain: "ATLogTest", code: 7)

    let line = #line + 1
    ATLog(.error, recorder.message(text), error: error)

    XCTAssertEqual(recorder.evaluations, 1)
    XCTAssertEqual(recorder.lines, ["[ERROR] ATLogMessageEvaluationTests.swift:\(line): \(text)\n\(error)"])
  }

  /// Release builds with no handler write only warnings and errors, with NSLog.
  func testUsesMessage_inReleaseWithoutHandler_onlyForWarningsAndErrors() {
    let used = [LogLevel.debug, .info, .warn, .error].map {
      atLogUsesMessage(at: $0, isDebugBuild: false, handlerMinimumLevel: nil)
    }

    XCTAssertEqual(used, [false, false, true, true])
  }

  /// A handler at `.info` still receives info lines in release builds.
  func testUsesMessage_inReleaseWithInfoHandler_includesInfo() {
    let used = [LogLevel.debug, .info, .warn, .error].map {
      atLogUsesMessage(at: $0, isDebugBuild: false, handlerMinimumLevel: .info)
    }

    XCTAssertEqual(used, [false, true, true, true])
  }

  /// A handler that keeps only warnings and errors lets release builds skip info messages.
  func testUsesMessage_inReleaseWithWarnHandler_skipsInfo() {
    let used = [LogLevel.debug, .info, .warn, .error].map {
      atLogUsesMessage(at: $0, isDebugBuild: false, handlerMinimumLevel: .warn)
    }

    XCTAssertEqual(used, [false, false, true, true])
  }

  /// A handler at `.error` does not stop warnings reaching NSLog.
  func testUsesMessage_inReleaseWithErrorHandler_stillBuildsWarnings() {
    XCTAssertTrue(atLogUsesMessage(at: .warn, isDebugBuild: false, handlerMinimumLevel: .error))
  }

  /// DEBUG builds write every level except `.debug` to os_log, whatever the handler keeps.
  func testUsesMessage_inDebug_forEveryLevelButDebug() {
    let used = [LogLevel.debug, .info, .warn, .error].map {
      atLogUsesMessage(at: $0, isDebugBuild: true, handlerMinimumLevel: .error)
    }

    XCTAssertEqual(used, [false, true, true, true])
  }

  /// The host's chosen minimum level is what `ATLog` checks against.
  @MainActor
  func testSetLogHandler_withMinimumLevel_isTheLevelATLogChecks() {
    DefaultAudiobookManager.setLogHandler(minimumLevel: .warn) { _, _, _ in }

    XCTAssertEqual(atLogHandlerMinimumLevel(), .warn)
  }

  /// Without a minimum level the handler keeps receiving info lines, as before.
  @MainActor
  func testSetLogHandler_withoutMinimumLevel_defaultsToInfo() {
    sharedLogHandlerMinimumLevel = .error

    DefaultAudiobookManager.setLogHandler { _, _, _ in }

    XCTAssertEqual(atLogHandlerMinimumLevel(), .info)
  }

  /// No handler means no handler level for release builds to honour.
  func testHandlerMinimumLevel_withoutHandler_isNil() {
    sharedLogHandler = nil

    XCTAssertNil(atLogHandlerMinimumLevel())
  }
}
