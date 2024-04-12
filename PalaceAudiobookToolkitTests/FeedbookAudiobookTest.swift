import Foundation
import XCTest
@testable import PalaceAudiobookToolkit

class FeedbookAudiobookTest: XCTestCase {
  
//  // TODO: Populate with actual profile data to test
//  let feedbookJsonTimeExpired = """
//  {
//  }
//  """
//  
//  // TODO: Populate with actual profile data to test
//  let feedbookJson = """
//  {
//  }
//  """
//
//  func testFeedBookTimeExpired() {
//    guard let feedbookData = feedbookJsonTimeExpired.data(using: .utf8) else {
//      XCTFail("Nil feedbook data")
//      return
//    }
//
//    guard let feedbookJsonObj = try? JSONSerialization.jsonObject(with: feedbookData, options: []) else {
//      XCTFail("Error parsing feedbook data")
//      return
//    }
//
//    guard let feedbookObj = feedbookJsonObj as? [String: Any] else {
//      XCTFail("Error casting jsonObject to Dictionary")
//      return
//    }
//
//    XCTAssertNil(Original_AudiobookFactory.audiobook(feedbookObj) , "AudiobookFactory should return nil for expired book")
//  }
  
  // This test is disabled until we populate `feedbookJson` with some json data
//  func testFeedBook() {
//    let feedbookData = feedbookJson.data(using: .utf8)
//    guard let feedbookObj = try! JSONSerialization.jsonObject(with: feedbookData!, options: []) as? [String: Any] else {
//      XCTAssert(false, "Error parsing feedbook data")
//      return
//    }
//
//    guard let feedbookAudiobook = AudiobookFactory.audiobook(feedbookObj) else {
//      XCTAssert(false, "AudiobookFactory returned nil")
//      return
//    }
//
//    feedbookAudiobook.deleteLocalContent()
//
//    guard let firstSpineItem = feedbookAudiobook.spine.first else {
//      XCTAssert(false, "Expected first spine item element to exist")
//      return
//    }
//
//    let delegate = TestFeedbookDownloadTaskDelegate()
//    firstSpineItem.downloadTask.delegate = delegate
//    firstSpineItem.downloadTask.fetch()
//    let startTime = Date.init(timeIntervalSinceNow: 0)
//    while !delegate.finished && startTime.timeIntervalSinceNow > -(60) { // One minute timeout
//      Thread.sleep(forTimeInterval: 2)
//    }
//    XCTAssert(delegate.finished, "Timed out")
//    XCTAssert(!delegate.failed, "Download failed")
//  }
}
