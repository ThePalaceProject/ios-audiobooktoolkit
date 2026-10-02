//
//  OverdriveResumeDataKeyTests.swift
//  PalaceAudiobookToolkitTests
//
//  Resume data replays the request it was recorded against, URL included. An
//  OverDrive track link expires and is replaced by re-fulfilling the book, so
//  resume data saved under the old link must not be found for the new one
//  (PP-4967).
//

import XCTest
@testable import PalaceAudiobookToolkit

final class OverdriveResumeDataKeyTests: XCTestCase {
  private let trackKey = "urn:org.thepalaceproject:readingOrder:3"
  private let expiredLink = URL(string: "https://od.example/track3.mp3?Expires=1000&Signature=old")!
  private let freshLink = URL(string: "https://od.example/track3.mp3?Expires=9000&Signature=new")!

  private func task(book: String = "book-1", url: URL) -> OverdriveDownloadTask {
    OverdriveDownloadTask(key: trackKey, url: url, mediaType: .audioMP3, bookID: book)
  }

  func testResumeDataKey_afterTheLinkIsReplaced_doesNotFindTheOldLinksData() {
    XCTAssertNotEqual(
      task(url: expiredLink).resumeDataKey,
      task(url: freshLink).resumeDataKey,
      "resume data recorded against the expired link would replay it against the fresh one"
    )
  }

  func testResumeDataKey_forTheSameTrackInAnotherBook_isDifferent() {
    XCTAssertNotEqual(
      task(book: "book-1", url: expiredLink).resumeDataKey,
      task(book: "book-2", url: expiredLink).resumeDataKey,
      "every book's third track has the same track key; resume data must not cross books"
    )
  }

  /// A download interrupted in one launch must still resume in the next, so the
  /// key is derived from stable inputs and not from per-process hashing.
  func testResumeDataKey_forTheSameBookTrackAndLink_isStableAcrossInstances() {
    XCTAssertEqual(task(url: freshLink).resumeDataKey, task(url: freshLink).resumeDataKey)
  }

  func testResumeDataKey_isNotTheBareTrackKey() {
    XCTAssertNotEqual(task(url: freshLink).resumeDataKey, trackKey)
  }
}
