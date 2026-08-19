//
//  FeedbookLicenseCheckTests.swift
//  PalaceAudiobookToolkitTests
//
//  PP-4981: the Feedbooks licence-status check had never run in production. The
//  request was built and never started, so the entire response handler was
//  unreachable code and no licence was ever actually checked.
//
//  These drive `performAsyncDrm` for real — stubbed transport, real audiobook,
//  asserting the resulting DRM status — rather than restating its predicate.
//  A test that reimplements the condition it is checking would have passed
//  happily for the whole time the feature was dead.
//

import XCTest
@testable import PalaceAudiobookToolkit

/// Serves canned licence-status responses.
///
/// `performAsyncDrm` uses `URLSession.shared`, which is not injectable, so the
/// seam has to be a registered `URLProtocol`.
private final class LicenseStubProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var _body: Data?
  private static var _failure: Error?
  private static var _requestCount = 0

  static func configure(body: Data?, failure: Error?) {
    lock.lock(); defer { lock.unlock() }
    _body = body; _failure = failure; _requestCount = 0
  }

  static var requestCount: Int {
    lock.lock(); defer { lock.unlock() }
    return _requestCount
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "licence.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self._requestCount += 1
    let body = Self._body
    let failure = Self._failure
    Self.lock.unlock()

    if let failure {
      client?.urlProtocol(self, didFailWithError: failure)
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let body { client?.urlProtocol(self, didLoad: body) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
final class FeedbookLicenseCheckTests: XCTestCase {

  private let licenseURL = URL(string: "https://licence.test/status")!

  override func setUp() {
    super.setUp()
    URLProtocol.registerClass(LicenseStubProtocol.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(LicenseStubProtocol.self)
    super.tearDown()
  }

  // MARK: - Helpers

  private func makeAudiobook() throws -> Audiobook {
    try XCTUnwrap(
      AudiobookFactory.audiobook(
        for: Manifest.mockManifest,
        bookIdentifier: "pp4981-license-check",
        decryptor: nil,
        token: nil
      ),
      "The fixture manifest must produce an audiobook; without one this suite proves nothing"
    )
  }

  /// Runs the check and waits for the request AND the main-actor hop the
  /// verdict takes. Polls rather than sleeping a fixed interval.
  private func runCheck(on book: Audiobook, statusJSON: String?, failure: Error? = nil) async {
    LicenseStubProtocol.configure(body: statusJSON?.data(using: .utf8), failure: failure)
    FeedbookDRMProcessor.performAsyncDrm(book: book, drmData: ["licenseCheckUrl": licenseURL])

    let deadline = Date().addingTimeInterval(3.0)
    while LicenseStubProtocol.requestCount == 0, Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    // The verdict is applied on the main actor one hop later; let it land.
    for _ in 0 ..< 20 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  // MARK: - Tests

  /// The PP-4981 regression itself. Before the fix the task was created and
  /// never resumed, so nothing was ever sent and every assertion below was
  /// vacuously satisfied by the default status.
  func testLicenseCheck_actuallyReachesTheNetwork() async throws {
    let book = try makeAudiobook()
    await runCheck(on: book, statusJSON: #"{"status":"active"}"#)

    XCTAssertGreaterThan(
      LicenseStubProtocol.requestCount, 0,
      "The licence request must be issued. A dataTask that is never resumed sends nothing — that is how this check stayed dead in production."
    )
  }

  /// The only outcome that removes access, so it is the one that must be
  /// deliberate. Kills a mutant that inverts or drops the status comparison.
  func testRevokedLicense_marksTheBookFailed() async throws {
    let book = try makeAudiobook()
    await runCheck(on: book, statusJSON: #"{"status":"revoked"}"#)

    XCTAssertEqual(
      book.drmStatus, .failed,
      "A licence the server no longer honours must remove access"
    )
  }

  /// A live loan must keep playing. `ready` and `active` are both live.
  func testActiveLicense_leavesTheBookPlayable() async throws {
    let book = try makeAudiobook()
    await runCheck(on: book, statusJSON: #"{"status":"active"}"#)

    XCTAssertNotEqual(book.drmStatus, .failed, "'active' is a live loan and must keep playing")
  }

  /// Fails OPEN, deliberately: a patron listening offline or on a flaky
  /// connection must not lose access because the licence server was
  /// unreachable. Only an explicit refusal removes access.
  func testUnreachableLicenseServer_doesNotRemoveAccess() async throws {
    let book = try makeAudiobook()
    await runCheck(
      on: book,
      statusJSON: nil,
      failure: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    )

    XCTAssertGreaterThan(LicenseStubProtocol.requestCount, 0, "the request must still be attempted")
    XCTAssertNotEqual(
      book.drmStatus, .failed,
      "An unreachable licence server must not remove access — offline listening is the point"
    )
  }

  /// A malformed body is not a refusal. Same reasoning as an unreachable
  /// server: only an explicit non-live status withdraws access.
  func testUnparseableResponse_doesNotRemoveAccess() async throws {
    let book = try makeAudiobook()
    await runCheck(on: book, statusJSON: "not json at all")

    XCTAssertNotEqual(book.drmStatus, .failed, "A body we cannot parse is not a refusal")
  }
}
