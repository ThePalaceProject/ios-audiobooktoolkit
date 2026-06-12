//
//  FindawayOversubdividedTOCTests.swift
//  PalaceAudiobookToolkitTests
//
//  Regression: 3.2.0 Findaway dual chapter-numbering on oversubdivided titles
//  ("Dune", Findaway id 32884). Multiple short TOC chapters map to ONE physical
//  audio file (findaway:1:3). 3.2.0 collapses the TOC app-side for DISPLAY, but the
//  TOOLKIT still resolves currentChapter / NowPlaying / saved-position against the
//  FULL uncollapsed list -> the chapter SHOWN disagrees with the chapter SAVED and
//  the one NowPlaying reports (dual numbering; a 30s skip inside the file never
//  advances the displayed chapter).
//
//  Invariant restored by the toolkit-side fix: the TOC is ONE collapsed list — one
//  chapter per physical track.key — so SHOWN == SAVED == NowPlaying.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class FindawayOversubdividedTOCTests: XCTestCase {
  private let testID = "testID"
  private let duneKey = "urn:org.thepalaceproject:findaway:1:3"

  private func loadDuneTOC() throws -> (AudiobookTableOfContents, Tracks) {
    let manifest = try Manifest.from(
      jsonFileName: "dune_oversubdivided_manifest",
      bundle: Bundle(for: type(of: self))
    )
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    return (AudiobookTableOfContents(manifest: manifest, tracks: tracks), tracks)
  }

  /// RED #1 — dual-numbering root: the toolkit TOC must collapse to ONE chapter per
  /// physical track.key (the list the UI shows), NOT one per readingOrder item.
  /// Fixture: 5 reading-order items, 3 distinct track.keys (1:1, 1:3, 1:4).
  func testOversubdividedFindaway_TOCCollapsesToOneChapterPerTrack() throws {
    let (toc, _) = try loadDuneTOC()
    XCTAssertEqual(
      toc.toc.count, 3,
      "Oversubdivided Findaway TOC must collapse to one chapter per physical track " +
      "(3 distinct keys 1:1/1:3/1:4); got \(toc.toc.count). Pre-fix == 5: the toolkit " +
      "list disagrees with the UI's collapsed list (dual numbering)."
    )
  }

  /// RED #2 — exactly ONE TOC index maps to the oversubdivided physical track (no dual
  /// numbering across its 3 sub-chapters).
  func testOversubdividedFindaway_OneChapterIndexPerPhysicalTrack() throws {
    let (toc, _) = try loadDuneTOC()
    let indices = toc.toc.indices.filter { toc.toc[$0].position.track.key == duneKey }
    XCTAssertEqual(
      indices.count, 1,
      "Exactly one TOC index must map to \(duneKey); multiple indices == dual numbering. Got \(indices)."
    )
  }

  /// RED #3 — KEEP-FIRST: the collapsed chapter IS the first sub-chapter unchanged
  /// (its own title + duration), matching the app's normalizedChapters. NOT a sum —
  /// the oversubdivided sub-durations are not additive sub-ranges of one physical
  /// file (real "Dune": Ch2's claimed 1257.874s exceeds the ~998s file).
  func testOversubdividedFindaway_CollapsedChapterKeepsFirstSubChapter() throws {
    let (toc, _) = try loadDuneTOC()
    let onDune = toc.toc.filter { $0.position.track.key == duneKey }
    XCTAssertEqual(onDune.count, 1, "Expected exactly one collapsed chapter for \(duneKey); got \(onDune.count).")
    XCTAssertEqual(onDune.first?.title, "Chapter 2", "Collapsed chapter keeps the FIRST sub-chapter's title.")
    XCTAssertEqual(
      onDune.first?.duration ?? -1, 1257.874, accuracy: 0.01,
      "Collapsed chapter keeps the FIRST sub-chapter's duration (keep-first, not sum)."
    )
  }

  /// RED #4 — SAVED == PLAYED: a real played position inside the oversubdivided file
  /// must resolve to a SINGLE chapter on the SAME physical track that is played, with a
  /// single TOC index (so the app's SAVED index == the NowPlaying index). Pre-fix the
  /// full list has 3 chapters on track 1:3, so the saved index disagrees with NowPlaying.
  func testOversubdividedFindaway_SavedChapterMatchesPlayedTrack_singleResolution() throws {
    let (toc, tracks) = try loadDuneTOC()
    guard let duneTrack = tracks.track(forKey: duneKey) else {
      return XCTFail("fixture must contain physical track \(duneKey)")
    }
    let played = TrackPosition(track: duneTrack, timestamp: 34.757, tracks: tracks)
    let shown = try toc.chapter(forPosition: played)
    XCTAssertEqual(
      shown.position.track.key, played.track.key,
      "Shown/saved chapter must be on the played track \(duneKey); got \(shown.position.track.key)."
    )
    let duneIndices = toc.toc.indices.filter { toc.toc[$0].position.track.key == duneKey }
    XCTAssertEqual(
      duneIndices.count, 1,
      "Exactly one TOC index maps to the played track \(duneKey); multiple == saved/NowPlaying desync. Got \(duneIndices)."
    )
  }

  /// NEGATIVE (PP-3518): legitimate multi-chapter-per-file with DISTINCT offsets
  /// (open-access "Dungeon Crawler Carl": Part I @t=1 and Chapter 2 @t=3 both in
  /// file 003) must NOT be collapsed — real navigation preserved.
  func testDungeonCrawlerCarl_distinctOffsetChaptersNotCollapsed() throws {
    let manifest = try Manifest.from(
      jsonFileName: "dungeon_crawler_carl_manifest", bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    XCTAssertEqual(toc.toc.count, 7, "DCC's 7 chapters must be preserved (distinct offsets); got \(toc.toc.count).")
    let partI = toc.toc.first { $0.title == "Part I" }
    let chapter2 = toc.toc.first { $0.title == "Chapter 2" }
    XCTAssertNotNil(partI, "Part I must be preserved.")
    XCTAssertNotNil(chapter2, "Chapter 2 must be preserved.")
    XCTAssertEqual(partI?.position.track.key, chapter2?.position.track.key, "Part I and Chapter 2 share one physical file...")
    XCTAssertNotEqual(partI?.position.timestamp, chapter2?.position.timestamp, "...at DISTINCT offsets, so both are kept.")
  }

  /// SWAP-GUARD: replacing the app's 1.5x gate with the toolkit collapse must NOT
  /// un-collapse a densely-subdivided title the app collapses today. "The Martian"
  /// (41 TOC entries over 8 files) is the ONE real shipping title that trips 1.5x;
  /// the toolkit must now collapse it to one chapter per physical file — the same
  /// grouping the app produced — fixing martian's latent toolkit/app divergence too.
  func testTheMartian_denseTOCCollapsesToOnePerFile() throws {
    let manifest = try Manifest.from(
      jsonFileName: "the_martian_manifest", bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    let distinctKeys = Set(toc.toc.map { $0.position.track.key }).count
    XCTAssertEqual(toc.toc.count, distinctKeys, "Dense TOC must collapse to one chapter per physical track.key.")
    XCTAssertLessThan(toc.toc.count, 41, "Martian's 41-entry dense TOC must be collapsed (was 41 uncollapsed).")
    XCTAssertEqual(toc.toc.count, 7, "Martian collapses to its 7 physical files (matches the app's 1.5x grouping).")
  }

  /// SWAP-GUARD (element-identical): martian must collapse to the SAME 7 chapters
  /// the app's keep-first-per-key produces today — TITLES + ORDER, not just count.
  /// A keep-first that picked different representatives would still be 7 but wrong.
  func testTheMartian_collapsedChaptersAreElementIdenticalToAppGrouping() throws {
    let manifest = try Manifest.from(
      jsonFileName: "the_martian_manifest", bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    let titles = toc.toc.map { $0.title }
    XCTAssertEqual(
      titles,
      ["Opening Credits", "Chapter 2", "Chapter 3", "Chapter 4", "Chapter 5", "Chapter 6", "Chapter 7"],
      "Collapsed martian must be element-identical (first chapter per physical file, in order) to the app's grouping."
    )
    // No duplicate physical keys remain.
    XCTAssertEqual(Set(toc.toc.map { $0.position.track.key }).count, toc.toc.count, "No duplicate track.key in collapsed TOC.")
  }

  /// NO-OP: a normal title with distinct keys, not dense, no @ts0 dups (Findaway
  /// "secret_lives": 10 unique (part,seq)) must be UNCHANGED — collapse is a no-op
  /// for the common case.
  func testNormalFindawayTitle_collapseIsNoOp() throws {
    let manifest = try Manifest.from(
      jsonFileName: "secret_lives_manifest", bundle: Bundle(for: type(of: self)))
    let tracks = Tracks(manifest: manifest, audiobookID: testID, token: nil)
    let toc = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    XCTAssertEqual(toc.toc.count, 10, "Normal Findaway title (10 unique keys) must be untouched by collapse; got \(toc.toc.count).")
    XCTAssertEqual(Set(toc.toc.map { $0.position.track.key }).count, 10, "All 10 chapters keep distinct physical keys.")
  }
}
