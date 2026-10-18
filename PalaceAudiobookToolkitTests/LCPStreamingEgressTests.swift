//
//  LCPStreamingEgressTests.swift
//  PalaceAudiobookToolkitTests
//
//  Measures how many bytes streaming an LCP audiobook pulls from the origin
//  per byte it serves to AVFoundation. A streamed `.lcpa` is one stored ZIP
//  holding every track, and Readium gives that archive a single 6 MB
//  `BufferingResource` shared by all entries, which it documents as "ignored
//  when reading backward or far ahead". Reads interleaved across tracks
//  therefore evict each other, and each eviction costs a whole buffer fill.
//

import AVFoundation
import ReadiumShared
import XCTest
@testable import PalaceAudiobookToolkit

final class LCPStreamingEgressTests: XCTestCase {

  // MARK: - Geometry of a real package

  /// Taken from a production `.lcpa`: 68 stored MP3 entries, ~24 MB each,
  /// in a 1.63 GB archive. The track stride is what matters — it is far
  /// wider than the buffer, so two tracks can never share one fill.
  private static let archiveLength: UInt64 = 1_630_000_000
  private static let trackStride: UInt64 = 24 * 1024 * 1024
  private static let trackLength: UInt64 = 20 * 1024 * 1024

  /// Readium's buffer size for a non-file archive
  /// (`ZIPFoundationArchiveFactory`: `let bufferSize = 6.MB`). Private there,
  /// so this is a copy, and nothing here detects it changing: the sweeps below
  /// inject their own archive buffer, so they pin the relationship between the
  /// two sizes rather than Readium's value.
  private static let readiumArchiveBufferSize = 6 * 1024 * 1024

  /// The loader's own read granularity (`transfer`'s `segmentSize`).
  private static let loaderSegment = 128 * 1024

  private var probe: ArchiveTransportProbe!

  override func setUp() {
    super.setUp()
    probe = ArchiveTransportProbe(length: Self.archiveLength)
  }

  override func tearDown() {
    probe = nil
    super.tearDown()
  }

  /// Defaults match the shipping loader; a test overrides only what it varies.
  private func makeLoader(
    perTrackBufferSize: Int = LCPResourceLoaderDelegate.defaultPerTrackBufferSize,
    maxBufferedTracks: Int = LCPResourceLoaderDelegate.defaultMaxBufferedTracks,
    trackCount: Int = 7,
    archiveBufferSize: Int = LCPStreamingEgressTests.readiumArchiveBufferSize,
    servableLength: UInt64? = nil,
    isLocalFile: Bool = false,
    publicationAvailableFrom: Date? = nil,
    publicationWaitTimeout: TimeInterval? = nil,
    cacheStore: ArchiveRangeStore? = nil
  ) -> LCPResourceLoaderDelegate {
    let provider = ArchiveProvider(
      probe: probe,
      trackCount: trackCount,
      stride: Self.trackStride,
      trackLength: Self.trackLength,
      archiveBufferSize: archiveBufferSize,
      servableLength: servableLength,
      cacheStore: cacheStore
    )
    provider.isLocalFile = isLocalFile
    provider.availableFrom = publicationAvailableFrom
    loaderProviders.append(provider)
    return LCPResourceLoaderDelegate(
      provider: provider,
      stallTimeout: 5,
      perTrackBufferSize: perTrackBufferSize,
      maxBufferedTracks: maxBufferedTracks,
      publicationWaitTimeout: publicationWaitTimeout
        ?? LCPResourceLoaderDelegate.defaultPublicationWaitTimeout
    )
  }

  /// The loader holds its provider weakly, so the test keeps it alive.
  private var loaderProviders: [ArchiveProvider] = []

  /// Bytes off the origin per byte handed to AVFoundation, reported so the
  /// number itself is in the record and not just the bound it satisfied.
  private func amplification(served: Int) -> Double {
    let ratio = Double(probe.bytesFetched) / Double(served)
    print(String(
      format: "egress: served %d B, transferred %d B in %d requests, amplification %.1fx",
      served, probe.bytesFetched, probe.requests, ratio
    ))
    return ratio
  }

  /// What a track's reads cost once its window is working.
  ///
  /// Not 1.0x: the plaintext length comes from decrypting the final block, so
  /// each track pays one tail read through the shared archive buffer, and that
  /// read is far from the data offset so it costs a whole fill. It happens
  /// once per track. These tests read one window per track, so that fill is
  /// 100% overhead here; across a whole 20 MB chapter it is nearer 1.3x.
  private static let steadyStateBound = 2.2

  // MARK: - What the access pattern costs

  /// Segments per track for the paired tests below. One archive buffer's
  /// worth, so a single fill is fully consumed and read-ahead is not charged
  /// as waste — the cases then differ only in the loader's buffering.
  private static let segmentsPerBufferFill = 48

  /// Two tracks, not the player's seven. The amplification is per read, so two
  /// interleaved tracks show it as plainly as seven; the parameter studies
  /// below cover the width of the window. Keeping this pair narrow matters:
  /// the unbuffered case moves a whole fill per read, and at seven tracks that
  /// was two gigabytes of churn per run, enough to starve the rest of the
  /// suite's clones.
  private static let pairedTracks = 0 ..< 2

  /// A scaled-down archive buffer for the parameter studies, which care about
  /// the shape of the relationship rather than the shipped magnitude.
  private static let scaledArchiveBuffer = 768 * 1024

  /// Reading one track in order is what Readium's archive buffer is built for:
  /// the first segment fills it and the rest are served from memory. This is
  /// the baseline, and the reason a straight sequential listen was never the
  /// thing inflating the bill.
  func testOneTrackInOrder_TransfersRoughlyWhatItServes() async throws {
    let loader = makeLoader()

    let served = try await read(track: 0, segments: Self.segmentsPerBufferFill, loader: loader)

    XCTAssertEqual(served, Self.segmentsPerBufferFill * Self.loaderSegment, "every requested segment is answered")
    XCTAssertLessThan(
      amplification(served: served),
      Self.steadyStateBound,
      "sequential reading inside one track must not refetch"
    )
  }

  /// The behaviour before the per-track buffer, reproduced by shrinking that
  /// buffer to a single segment so it can hold nothing between reads. Reads
  /// arriving for more than one track land outside the one shared archive
  /// window, and each pays a whole fill to answer 128 KB.
  ///
  /// Paired with the test below: same tracks, same segments, same archive
  /// buffer, so the only variable is the size of the loader's own buffer.
  func testTwoTracksInterleaved_WithNoUsablePerTrackBuffer_RefetchesEveryRead() async throws {
    let loader = makeLoader(perTrackBufferSize: Self.loaderSegment)

    let served = try await readRoundRobin(
      tracks: Self.pairedTracks,
      segmentsPerTrack: Self.segmentsPerBufferFill,
      loader: loader
    )

    XCTAssertEqual(
      served,
      Self.pairedTracks.count * Self.segmentsPerBufferFill * Self.loaderSegment,
      "every requested segment is answered"
    )
    XCTAssertGreaterThan(
      amplification(served: served),
      8,
      "with nothing buffered per track, interleaved reads thrash the one shared window"
    )
  }

  /// The fix as shipped, on the same workload. A track's reads come out of its
  /// own window, so one archive fill is consumed before another track can
  /// displace it.
  func testTwoTracksInterleaved_WithThePerTrackBuffer_TransfersRoughlyWhatItServes() async throws {
    let loader = makeLoader()

    let served = try await readRoundRobin(
      tracks: Self.pairedTracks,
      segmentsPerTrack: Self.segmentsPerBufferFill,
      loader: loader
    )

    XCTAssertEqual(
      served,
      Self.pairedTracks.count * Self.segmentsPerBufferFill * Self.loaderSegment,
      "every requested segment is answered"
    )
    XCTAssertLessThan(
      amplification(served: served),
      Self.steadyStateBound,
      "a per-track window must remove the refetch the test above measures"
    )
  }

  /// Fixes the buffer size by measurement: below the archive buffer a
  /// proportional refetch remains. Run against a scaled-down archive buffer,
  /// because what has to hold is the relationship, not the magnitude.
  func testPerTrackBufferSize_BelowTheArchiveBuffer_LeavesRefetchBehind() async throws {
    let fill = Self.scaledArchiveBuffer
    var measured: [(size: Int, ratio: Double)] = []
    for size in [fill / 4, fill] {
      probe = ArchiveTransportProbe(length: Self.archiveLength)
      let loader = makeLoader(
        perTrackBufferSize: size,
        maxBufferedTracks: 8,
        archiveBufferSize: fill
      )
      let served = try await readRoundRobin(
        tracks: 0 ..< 7,
        segmentsPerTrack: fill / Self.loaderSegment,
        loader: loader
      )
      let ratio = Double(probe.bytesFetched) / Double(served)
      print(String(format: "per-track buffer %4d KB of %d KB archive -> amplification %.1fx", size / 1024, fill / 1024, ratio))
      measured.append((size, ratio))
    }

    let matched = try XCTUnwrap(measured.last)
    let quarter = try XCTUnwrap(measured.first)
    XCTAssertLessThan(
      matched.ratio,
      Self.steadyStateBound,
      "a buffer matching the archive buffer removes the refetch"
    )
    XCTAssertGreaterThan(
      quarter.ratio,
      matched.ratio * 2,
      "a quarter-sized buffer cannot consume a fill, so it must do measurably worse"
    )
  }

  /// The cost of the bound, which is why it has to cover the player's whole
  /// prefetch window. Reads arriving round-robin over more tracks than are
  /// buffered evict the entry needed next, so the hit rate is zero and the
  /// benefit is not reduced but lost.
  func testBoundBelowTheInterleavedSet_LosesTheBenefitRatherThanReducingIt() async throws {
    let fill = Self.scaledArchiveBuffer
    var measured: [(bound: Int, ratio: Double)] = []
    for bound in [4, 8] {
      probe = ArchiveTransportProbe(length: Self.archiveLength)
      let loader = makeLoader(
        perTrackBufferSize: fill,
        maxBufferedTracks: bound,
        archiveBufferSize: fill
      )
      let served = try await readRoundRobin(
        tracks: 0 ..< 7,
        segmentsPerTrack: fill / Self.loaderSegment,
        loader: loader
      )
      let ratio = Double(probe.bytesFetched) / Double(served)
      print(String(format: "bound %d of 7 interleaved -> amplification %.1fx", bound, ratio))
      measured.append((bound, ratio))
    }

    let starved = try XCTUnwrap(measured.first)
    let covering = try XCTUnwrap(measured.last)
    XCTAssertLessThan(
      covering.ratio,
      Self.steadyStateBound,
      "a bound covering the window removes the refetch"
    )
    XCTAssertGreaterThan(
      starved.ratio,
      covering.ratio * 4,
      "a bound below the interleaved set must be seen to lose the benefit, not merely reduce it"
    )
  }

  /// The bound has to hold exactly as many tracks as it says. Interleaving
  /// precisely `maxBufferedTracks` tracks leaves no slack: holding one fewer
  /// turns the round-robin into a cycle longer than the cache, and the hit
  /// rate goes to zero. This pins the boundary, which the ratio tests above
  /// cannot — they interleave fewer tracks than the bound, so an off-by-one
  /// there still measures 1.0x.
  func testBoundHoldsExactlyItsStatedNumberOfTracks() async throws {
    let fill = Self.scaledArchiveBuffer
    let bound = 4
    let loader = makeLoader(
      perTrackBufferSize: fill,
      maxBufferedTracks: bound,
      archiveBufferSize: fill
    )

    let served = try await readRoundRobin(
      tracks: 0 ..< bound,
      segmentsPerTrack: fill / Self.loaderSegment,
      loader: loader
    )

    XCTAssertEqual(served, bound * fill, "every requested segment is answered")
    XCTAssertLessThan(
      amplification(served: served),
      Self.steadyStateBound,
      "a bound of \(bound) must keep \(bound) tracks, not \(bound - 1)"
    )
  }

  /// The per-track buffer asks for a whole fill beyond the read it is serving,
  /// so it has to know the track's length or it reads past the end. Readium's
  /// buffer memoizes any successful length answer including a nil one, so a
  /// length served from a cache that is not filled yet would leave the clamp
  /// dead for the resource's whole life and every later read overshooting — the
  /// `rangeOutOfBounds` shape of PP-4542.
  ///
  /// This drives reads that never trigger a content-information phase, which is
  /// the ordering that exposes it, and pins that nothing is asked for beyond
  /// the track.
  func testReadsNearTheTrackEnd_NeverAskBeyondIt() async throws {
    let loader = makeLoader(trackCount: 1)
    let lastSegment = Int(Self.trackLength) / Self.loaderSegment - 1

    let served = try await readSegment(track: 0, index: lastSegment, loader: loader)
    let entry = try XCTUnwrap(loaderProviders.last?.entry(forTrack: 0))

    XCTAssertEqual(served, Self.loaderSegment, "the final segment is answered in full")
    XCTAssertLessThanOrEqual(
      entry.highestRequestedEnd,
      Self.trackLength,
      "a read near the end must not ask past the track; the buffer's clamp has to be live"
    )
  }

  // MARK: - What the first byte costs

  /// Where a resumed listen starts reading: the device log that opened this
  /// investigation showed a restore to 371.2 s of a track, and at the
  /// package's ~128 kbps that lands about 5.8 MB in. It matters because a
  /// cold read at an offset cannot be served by a buffer fill that starts at
  /// zero — every window in the chain has to fill from the offset first.
  private static let resumeOffset = 5_800_000 / LCPStreamingEgressTests.loaderSegment
    * LCPStreamingEgressTests.loaderSegment

  /// What one cold track costs off the origin: the tail read that resolves the
  /// plaintext length, plus the fill that serves the data. Both go through the
  /// shared archive buffer at offsets far apart, so each is a whole fill.
  private static let coldTrackBound =
    2 * LCPStreamingEgressTests.readiumArchiveBufferSize + LCPStreamingEgressTests.loaderSegment

  /// Cost of the first segment a resumed listen asks for, which is what the
  /// patron waits through before audio starts and what the 30 s publication
  /// load timeout is racing.
  ///
  /// Measured because steady-state amplification and time-to-first-byte are
  /// different quantities and a change can move them in opposite directions:
  /// every fill that removes a refetch later is also work in front of the
  /// first byte now. The egress tests above pin the first; nothing pinned the
  /// second, and a regression there shows up to a patron as a book that will
  /// not start.
  func testFirstSegmentOfAResumedTrack_CostsNoMoreThanOneArchiveFill() async throws {
    let loader = makeLoader(trackCount: 1)

    let served = try await readSegment(
      track: 0,
      offset: Self.resumeOffset,
      loader: loader
    )

    XCTAssertEqual(served, Self.loaderSegment, "the resumed segment is answered in full")
    print(String(
      format: "cold start: served %d B, transferred %d B in %d requests",
      served, probe.bytesFetched, probe.requests
    ))
    XCTAssertLessThanOrEqual(
      probe.bytesFetched,
      Self.coldTrackBound,
      "a cold mid-track read costs the tail probe's fill plus the data fill "
        + "and no more: the per-track window must not stack a third"
    )
  }

  /// The same question for the whole prefetch window, because the player does
  /// not open one track — `rebuildPlayerQueueAndNavigate` builds a seven-item
  /// queue and AVFoundation asks all of them for content information at once.
  /// The bound is per track, so this pins that the window's cost stays linear
  /// in the number of items rather than multiplying.
  func testOpeningThePrefetchWindow_CostsOneFillPerTrack() async throws {
    let loader = makeLoader(trackCount: 7)

    // Two passes, because one cannot see the bound at all: reading each track
    // once never revisits an entry, so a bound of 1 measures the same as the
    // shipped 8. The second pass is served from each track's window only if
    // all seven survived the first.
    var served = 0
    for _ in 0 ..< 2 {
      for track in 0 ..< 7 {
        served += try await readSegment(track: track, offset: Self.resumeOffset, loader: loader)
      }
    }

    XCTAssertEqual(served, 2 * 7 * Self.loaderSegment, "every item in the window is answered")
    print(String(
      format: "window open: served %d B, transferred %d B in %d requests",
      served, probe.bytesFetched, probe.requests
    ))
    XCTAssertLessThanOrEqual(
      probe.bytesFetched,
      7 * Self.coldTrackBound,
      """
      opening the window costs each item one tail probe and one fill, once. \
      A bound narrower than the window would pay them again on the second pass
      """
    )
  }

  /// A track read again must be kept ahead of one not touched since, which is
  /// the difference between this cache and a queue.
  ///
  /// It matters because the player's reads are not monotonic: a backward seek
  /// or an out-of-order prefetch returns to a track whose entry was inserted
  /// long ago. Under insertion order that hot entry is evicted ahead of a cold
  /// one added more recently, and the track being listened to is the one that
  /// loses its window.
  ///
  /// Reading each track once cannot show this, and neither can a round-robin
  /// wider than the bound, where everything misses anyway — so the access
  /// pattern here revisits a track before the eviction that would drop it.
  func testATrackReadAgainOutlivesOneNotTouchedSince() async throws {
    let loader = makeLoader(
      maxBufferedTracks: 2,
      trackCount: 3,
      archiveBufferSize: Self.scaledArchiveBuffer
    )

    _ = try await readSegment(track: 0, index: 0, loader: loader)
    _ = try await readSegment(track: 1, index: 0, loader: loader)
    // Promotes track 0 ahead of track 1.
    _ = try await readSegment(track: 0, index: 0, loader: loader)
    // Evicts the least recently used, which must be track 1, not track 0.
    _ = try await readSegment(track: 2, index: 0, loader: loader)

    let beforeRevisit = probe.bytesFetched
    _ = try await readSegment(track: 0, index: 0, loader: loader)

    XCTAssertEqual(
      probe.bytesFetched,
      beforeRevisit,
      """
      track 0 was read more recently than track 1, so track 1 is what the \
      bound of 2 must drop; refetching track 0 here means the cache evicts in \
      insertion order and the track being listened to loses its window
      """
    )
  }

  // MARK: - Opening a book whose publication is still arriving

  /// A request issued before the publication has opened must wait for it, not
  /// be failed.
  ///
  /// On a newly borrowed book the publication opens over the network, so the
  /// first loading requests arrive before it exists. Failing them is not
  /// recoverable: the player has already built its items, and
  /// `publicationDidLoad` only rebuilds when the queue is EMPTY, so the failed
  /// items stay, `isLoaded` never flips, and 30 s later the player reports
  /// "Timed out waiting for LCP publication to load" and the book closes. A
  /// second open works because the publication is cached by then, which is why
  /// this only ever showed up on a first open (PP-5368).
  func testRequestBeforeThePublicationOpens_WaitsForItRatherThanFailing() async throws {
    let loader = makeLoader(
      trackCount: 1,
      publicationAvailableFrom: Date().addingTimeInterval(1.5)
    )

    let served = try await readSegment(track: 0, index: 0, loader: loader)

    XCTAssertEqual(
      served,
      Self.loaderSegment,
      "the segment must be served once the publication arrives"
    )
  }

  /// A publication that never opens must still fail the request, rather than
  /// leaving AVFoundation waiting on an answer that never comes.
  ///
  /// The wait has to end somewhere: a request held forever is a chapter whose
  /// spinner never resolves and which reports nothing a caller can act on.
  func testRequestWhenThePublicationNeverOpens_IsFailedNotLeftWaiting() async throws {
    let loader = makeLoader(
      trackCount: 1,
      publicationAvailableFrom: Date().addingTimeInterval(3600),
      publicationWaitTimeout: 0.5
    )

    let request = RecordingRequest(
      url: URL(string: "readium-lcp://track0/track0.mp3")!,
      range: LCPRequestedRange(offset: 0, length: Self.loaderSegment, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: request), "the loader takes the request on")

    let outcome = try await request.waitUntilFinished(timeout: 20)
    guard case .failure = outcome else {
      return XCTFail("a publication that never opens must fail the request, got \(outcome)")
    }
    XCTAssertEqual(request.respondedBytes, 0, "nothing was served")
  }

  // MARK: - A local package is not a remote one

  /// Readium's buffer for a file-backed archive is 16 kB with no buffering
  /// wrapper at all (`ZIPFoundationArchiveFactory`), because a local read has
  /// no request to avoid making. A per-track window there would read and
  /// decrypt its whole size to serve one 128 KB segment and save nothing, and
  /// the player rebuilds its queue on every chapter change and seek, so that
  /// cost recurs for the life of the listen.
  ///
  /// Measured on a downloaded package: the reads must stay proportional to
  /// what was asked for, not to the window the streaming case needs.
  func testLocalPackage_DoesNotPayForAStreamingWindow() async throws {
    let fileArchiveBuffer = 16 * 1024
    let loader = makeLoader(
      trackCount: 1,
      archiveBufferSize: fileArchiveBuffer,
      isLocalFile: true
    )

    let served = try await readSegment(track: 0, offset: Self.resumeOffset, loader: loader)

    XCTAssertEqual(served, Self.loaderSegment, "the segment is answered in full")
    print(String(
      format: "local open: served %d B, transferred %d B in %d requests",
      served, probe.bytesFetched, probe.requests
    ))
    XCTAssertLessThan(
      probe.bytesFetched,
      Self.defaultPerTrackBufferSizeForComparison,
      """
      a local package must not pull a streaming-sized window per track; there \
      is no origin to save a request against
      """
    )
  }

  /// Named rather than inlined so the comparison is against the shipped value.
  private static let defaultPerTrackBufferSizeForComparison =
    LCPResourceLoaderDelegate.defaultPerTrackBufferSize

  /// What a cold first open costs off the origin, driven by the window the
  /// player actually builds rather than a number repeated here.
  ///
  /// This is the quantity a patron waits through before audio starts, and the
  /// one the 30 s publication load timeout is racing. Each item in the window
  /// costs a tail probe and a fill, so the cost is linear in the window and
  /// the window is the only lever.
  func testColdFirstOpen_CostsOnlyWhatTheWindowHolds() async throws {
    let window = LCPStreamingPlayer.queueWindow(targetIndex: 3, trackCount: 20)
    let loader = makeLoader(trackCount: 20)

    var served = 0
    for track in window {
      served += try await readSegment(track: track, offset: Self.resumeOffset, loader: loader)
    }

    print(String(
      format: "cold first open: %d item(s), served %d B, transferred %d B in %d requests",
      window.count, served, probe.bytesFetched, probe.requests
    ))
    // Without this the bound below passes on an empty window, where nothing is
    // read and nothing is fetched.
    XCTAssertEqual(
      served,
      window.count * Self.loaderSegment,
      "every item in the window is answered in full"
    )
    XCTAssertGreaterThan(served, 0, "a first open must read the chapter it opens")
    XCTAssertLessThanOrEqual(
      probe.bytesFetched,
      Self.coldTrackBound,
      """
      a first open must fetch no more than the one chapter the queue holds; \
      at seven items it was about 88 MB and books did not start
      """
    )
  }

  // MARK: - Time to first audio (PP-5367)

  /// What the patron waits through before the first sample of a cold chapter
  /// can play, measured as bytes off the origin before the first byte is handed
  /// back.
  ///
  /// A different quantity from the amplification above, and they move in
  /// opposite directions: read-ahead that removes a refetch later is work in
  /// front of the first byte now. The owner's bar is that switching chapters
  /// does not make the patron feel their network, so this is the number the
  /// streaming path is tuned against; nothing pinned it before.
  ///
  /// Driven with the three requests AVFoundation actually makes on a cold
  /// item: content information, a tail probe for duration and metadata, and
  /// then the audio read at the start of the chapter.
  func testColdChapterOpen_BytesBeforeTheFirstSampleIsServed() async throws {
    let loader = makeLoader(trackCount: 20)
    let track = 3

    // 1. Content information. No range, so this resolves the plaintext length
    //    and serves no bytes.
    let info = RecordingRequest(
      url: Self.trackURL(track),
      range: nil,
      needsContentInformation: true
    )
    XCTAssertTrue(loader.shouldWait(for: info))
    let infoOutcome = try await info.waitUntilFinished(timeout: 20)
    XCTAssertEqual(infoOutcome, .success)
    let afterContentInformation = probe.bytesFetched

    // 2. The tail probe: AVPlayer reads the last bytes of the track for
    //    duration and metadata before it reads any audio.
    let tailOffset = Int(Self.trackLength) - Self.loaderSegment
    let tail = RecordingRequest(
      url: Self.trackURL(track),
      range: LCPRequestedRange(offset: Int64(tailOffset), length: Self.loaderSegment, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: tail))
    let tailOutcome = try await tail.waitUntilFinished(timeout: 20)
    XCTAssertEqual(tailOutcome, .success)
    let afterTailProbe = probe.bytesFetched

    // 3. The audio read, at the start of the chapter.
    let audio = RecordingRequest(
      url: Self.trackURL(track),
      range: LCPRequestedRange(offset: 0, length: Self.loaderSegment, toEnd: false)
    )
    var bytesBeforeFirstSample: Int?
    audio.onFirstRespond = { [probe] in bytesBeforeFirstSample = probe.bytesFetched }
    XCTAssertTrue(loader.shouldWait(for: audio))
    let audioOutcome = try await audio.waitUntilFinished(timeout: 20)
    XCTAssertEqual(audioOutcome, .success)

    let beforeFirstSample = try XCTUnwrap(bytesBeforeFirstSample, "no audio byte was ever served")
    print(String(
      format: "cold chapter open: content information %d B, tail probe +%d B, "
        + "bytes before the first audio sample %d B in %d requests",
      afterContentInformation,
      afterTailProbe - afterContentInformation,
      beforeFirstSample,
      probe.requests
    ))
    for range in probe.ranges {
      print(String(
        format: "  origin range %10llu ..< %10llu -> %8d B",
        range.lower, range.upper, range.count
      ))
    }
    XCTAssertEqual(audio.respondedBytes, Self.loaderSegment, "the audio read is answered in full")
    XCTAssertLessThanOrEqual(
      beforeFirstSample,
      Self.timeToFirstAudioBound,
      """
      a cold chapter must start on about one archive fill, not on a fill per \
      request: every extra fill in front of the first sample is a second the \
      patron spends looking at a frozen 0:00
      """
    )
  }

  /// The same cold open with the byte-range cache under Readium's archive
  /// buffer, which is where the app puts it.
  ///
  /// The three fills are 96,460,800, 96,337,920 and 75,497,472. The first two
  /// overlap by 6,168,576 bytes, so with the fetched bytes kept the tail probe
  /// costs the 122,880 it missed instead of a second whole fill. The third is
  /// 20 MB away and is genuinely new, so it still costs a fill: this removes one
  /// of the three round trips in front of the first sample, not all of them.
  func testColdChapterOpen_WithTheByteRangeCache_SavesTheOverlappingFill() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("egress-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PartialArchiveStore.open(directory: directory, totalSize: Self.archiveLength)
    defer { store.close() }

    let loader = makeLoader(trackCount: 20, cacheStore: store)
    let track = 3

    let info = RecordingRequest(url: Self.trackURL(track), range: nil, needsContentInformation: true)
    XCTAssertTrue(loader.shouldWait(for: info))
    let infoOutcome = try await info.waitUntilFinished(timeout: 20)
    XCTAssertEqual(infoOutcome, .success)

    let tailOffset = Int(Self.trackLength) - Self.loaderSegment
    let tail = RecordingRequest(
      url: Self.trackURL(track),
      range: LCPRequestedRange(offset: Int64(tailOffset), length: Self.loaderSegment, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: tail))
    let tailOutcome = try await tail.waitUntilFinished(timeout: 20)
    XCTAssertEqual(tailOutcome, .success)

    let audio = RecordingRequest(
      url: Self.trackURL(track),
      range: LCPRequestedRange(offset: 0, length: Self.loaderSegment, toEnd: false)
    )
    var bytesBeforeFirstSample: Int?
    audio.onFirstRespond = { [probe] in bytesBeforeFirstSample = probe.bytesFetched }
    XCTAssertTrue(loader.shouldWait(for: audio))
    let audioOutcome = try await audio.waitUntilFinished(timeout: 20)
    XCTAssertEqual(audioOutcome, .success)

    let beforeFirstSample = try XCTUnwrap(bytesBeforeFirstSample, "no audio byte was ever served")
    print(String(
      format: "cold chapter open, with the byte-range cache: bytes before the first audio sample %d B in %d requests",
      beforeFirstSample, probe.requests
    ))
    for range in probe.ranges {
      print(String(format: "  origin range %10llu ..< %10llu -> %8d B", range.lower, range.upper, range.count))
    }

    XCTAssertEqual(audio.respondedBytes, Self.loaderSegment, "the audio read is answered in full")
    XCTAssertLessThan(
      beforeFirstSample,
      Self.timeToFirstAudioBound,
      """
      keeping the fetched bytes must remove the overlapping fill, so a cold     chapter costs strictly less than the three fills it cost before
      """
    )
    XCTAssertLessThanOrEqual(
      beforeFirstSample,
      2 * Self.readiumArchiveBufferSize + Self.loaderSegment,
      """
      two fills and the segment: the content-information read, the audio read     20 MB away, and the 122,880 bytes the tail probe did not already hold
      """
    )
  }


  /// Attribution: the same cold open with the loader's own per-track buffer
  /// switched OFF (`archiveIsLocalFile` true), against the same 6 MB Readium
  /// archive buffer. If the bytes before the first sample do not move, the cost
  /// is the archive buffer underneath the loader and not the loader's
  /// read-ahead, and no change to WHICH reads the loader buffers can reduce it.
  func testColdChapterOpen_WithNoPerTrackBuffer_CostsTheSame() async throws {
    let loader = makeLoader(trackCount: 20, isLocalFile: true)
    let track = 3

    let info = RecordingRequest(url: Self.trackURL(track), range: nil, needsContentInformation: true)
    XCTAssertTrue(loader.shouldWait(for: info))
    let infoOutcome = try await info.waitUntilFinished(timeout: 20)
    XCTAssertEqual(infoOutcome, .success)

    let tailOffset = Int(Self.trackLength) - Self.loaderSegment
    let tail = RecordingRequest(
      url: Self.trackURL(track),
      range: LCPRequestedRange(offset: Int64(tailOffset), length: Self.loaderSegment, toEnd: false)
    )
    XCTAssertTrue(loader.shouldWait(for: tail))
    let tailOutcome = try await tail.waitUntilFinished(timeout: 20)
    XCTAssertEqual(tailOutcome, .success)

    let audio = RecordingRequest(
      url: Self.trackURL(track),
      range: LCPRequestedRange(offset: 0, length: Self.loaderSegment, toEnd: false)
    )
    var bytesBeforeFirstSample: Int?
    audio.onFirstRespond = { [probe] in bytesBeforeFirstSample = probe.bytesFetched }
    XCTAssertTrue(loader.shouldWait(for: audio))
    let audioOutcome = try await audio.waitUntilFinished(timeout: 20)
    XCTAssertEqual(audioOutcome, .success)

    let beforeFirstSample = try XCTUnwrap(bytesBeforeFirstSample)
    print(String(
      format: "cold chapter open, no per-track buffer: bytes before the first audio sample %d B in %d requests",
      beforeFirstSample, probe.requests
    ))
    for range in probe.ranges {
      print(String(format: "  origin range %10llu ..< %10llu -> %8d B", range.lower, range.upper, range.count))
    }
    XCTAssertEqual(audio.respondedBytes, Self.loaderSegment)
  }

  /// What a cold chapter open costs today: three archive fills and the segment.
  ///
  /// Measured, and each fill is attributable:
  ///   - the content-information read, which resolves the plaintext length from
  ///     the last bytes of the entry;
  ///   - AVFoundation's tail probe, 128 kB from the end — 122,880 bytes BEFORE
  ///     the length read, and Readium's archive buffer does not serve a read
  ///     that starts behind its window, so this is a second fill;
  ///   - the audio read at the start of the chapter, 20 MB away from both.
  ///
  /// The fills are Readium's, not this loader's. `ZIPFoundationArchiveFactory`
  /// buffers a remote archive at 6 MB, so every read that misses that window
  /// costs a whole one whatever this loader asks for — which
  /// `testColdChapterOpen_WithNoPerTrackBuffer_CostsTheSame` demonstrates by
  /// switching the per-track buffer off and measuring the same figure. So no
  /// change to WHICH reads this loader buffers can move this number; what moves
  /// it is not discarding what the fills already fetched.
  ///
  /// The bound pins today's cost so a fourth fill cannot appear unnoticed.
  private static let timeToFirstAudioBound =
    3 * LCPStreamingEgressTests.readiumArchiveBufferSize + LCPStreamingEgressTests.loaderSegment

  private static func trackURL(_ track: Int) -> URL {
    URL(string: "readium-lcp://track\(track)/track\(track).mp3")!
  }

  // MARK: - The length/size mismatch

  /// A track whose archive serves fewer bytes than the LCP resource reports
  /// must still hand AVFoundation the bytes that DO exist.
  ///
  /// This is the PP-4542 shape: ZIPFoundation throws `rangeOutOfBounds` once a
  /// range passes the entry's uncompressed size, and AVPlayer's first-open tail
  /// probe reads the last bytes of a track for duration and metadata, so it
  /// lands in exactly that region. `readClampedToAvailable` exists to find the
  /// real end by binary search and serve the readable prefix.
  ///
  /// The search works by varying the range's UPPER bound, so it only finds
  /// anything if the resource it reads through honours that bound. A
  /// `BufferingResource` does not: its fetch is
  /// `lowerBound ..< max(requested.upperBound, lowerBound + bufferSize)`, which
  /// for any read smaller than the buffer ignores the caller's upper bound
  /// entirely. Every probe then fetches the same over-long range and fails the
  /// same way, the search converges on nothing, and the request is finished
  /// SUCCESSFULLY having served zero bytes — a chapter that reports fine and
  /// plays silence.
  func testReadPastTheServableEnd_StillServesTheBytesThatExist() async throws {
    let servable = Self.trackLength - 1024 * 1024
    let loader = makeLoader(trackCount: 1, servableLength: servable)

    // Starts inside what the archive can serve and asks past it, which is what
    // a tail probe does.
    let start = Int(servable) - 64 * 1024
    let served = try await readSegmentAllowingShortRead(
      track: 0,
      offset: start,
      loader: loader
    )

    XCTAssertEqual(
      served,
      64 * 1024,
      """
      the readable prefix must reach AVFoundation; zero bytes on a successful \
      request is the tail probe that kills the chapter
      """
    )
  }

  // MARK: - Driving the loader

  /// Asks the loader for `segments` consecutive 128 KB ranges of one track and
  /// returns the byte count it served.
  private func read(
    track: Int,
    segments: Int,
    loader: LCPResourceLoaderDelegate
  ) async throws -> Int {
    var served = 0
    for index in 0 ..< segments {
      served += try await readSegment(track: track, index: index, loader: loader)
    }
    return served
  }

  /// Walks the tracks in round-robin, one segment each pass, which is the
  /// shape a multi-item prefetch window produces.
  private func readRoundRobin(
    tracks: Range<Int>,
    segmentsPerTrack: Int,
    loader: LCPResourceLoaderDelegate
  ) async throws -> Int {
    var served = 0
    for index in 0 ..< segmentsPerTrack {
      for track in tracks {
        served += try await readSegment(track: track, index: index, loader: loader)
      }
    }
    return served
  }

  private func readSegment(
    track: Int,
    index: Int,
    loader: LCPResourceLoaderDelegate
  ) async throws -> Int {
    try await readSegment(track: track, offset: index * Self.loaderSegment, loader: loader)
  }

  /// Like `readSegment`, but does not require a full segment: the clamped
  /// read deliberately returns less than asked for at the end of a track.
  private func readSegmentAllowingShortRead(
    track: Int,
    offset: Int,
    loader: LCPResourceLoaderDelegate
  ) async throws -> Int {
    let request = RecordingRequest(
      url: URL(string: "readium-lcp://track\(track)/track\(track).mp3")!,
      range: LCPRequestedRange(
        offset: Int64(offset),
        length: Self.loaderSegment,
        toEnd: false
      )
    )
    XCTAssertTrue(loader.shouldWait(for: request), "the loader must accept a well-formed request")
    let outcome = try await request.waitUntilFinished(timeout: 20)
    XCTAssertEqual(outcome, .success, "a clamped read must finish successfully")
    return request.respondedBytes
  }

  /// Byte-offset form, for the cold-start cases that start part-way into a
  /// track rather than at a segment index counted from zero.
  private func readSegment(
    track: Int,
    offset: Int,
    loader: LCPResourceLoaderDelegate
  ) async throws -> Int {
    let request = RecordingRequest(
      url: URL(string: "readium-lcp://track\(track)/track\(track).mp3")!,
      range: LCPRequestedRange(
        offset: Int64(offset),
        length: Self.loaderSegment,
        toEnd: false
      )
    )
    XCTAssertTrue(loader.shouldWait(for: request), "the loader must accept a well-formed request")
    let outcome = try await request.waitUntilFinished(timeout: 20)
    XCTAssertEqual(outcome, .success, "track \(track) at offset \(offset) must be served")
    return request.respondedBytes
  }
}

// MARK: - Fakes

/// Records what the transport moved. This is the quantity an origin bills on,
/// so it is measured at the one place that talks to the network and nowhere
/// above it.
private final class ArchiveTransportProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var _bytesFetched = 0
  private var _requests = 0
  private var _highestRequestedEnd: UInt64 = 0
  private var _ranges: [(lower: UInt64, upper: UInt64, count: Int)] = []
  let length: UInt64

  init(length: UInt64) { self.length = length }

  var bytesFetched: Int { lock.withLock { _bytesFetched } }
  var requests: Int { lock.withLock { _requests } }
  /// Highest upper bound any read asked for, before the origin clamped it.
  var highestRequestedEnd: UInt64 { lock.withLock { _highestRequestedEnd } }
  /// Every range the origin was asked for, in order. Read by the cold-open
  /// measurement, which needs to know WHICH reads cost a fill, not only how
  /// many bytes moved in total.
  var ranges: [(lower: UInt64, upper: UInt64, count: Int)] { lock.withLock { _ranges } }

  func note(_ count: Int, requestedLower: UInt64, requestedEnd: UInt64) {
    lock.withLock {
      _requests += 1
      _bytesFetched += count
      _highestRequestedEnd = max(_highestRequestedEnd, requestedEnd)
      _ranges.append((requestedLower, requestedEnd, count))
    }
  }
}

/// The `.lcpa` as the origin sees it: one object, served by range.
private final class ArchiveResource: Resource {
  private let probe: ArchiveTransportProbe

  init(probe: ArchiveTransportProbe) { self.probe = probe }

  let sourceURL: AbsoluteURL? = nil
  func properties() async -> ReadResult<ResourceProperties> { .success(ResourceProperties()) }
  func estimatedLength() async -> ReadResult<UInt64?> { .success(probe.length) }

  func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
    let lower = min(range?.lowerBound ?? 0, probe.length)
    let upper = min(range?.upperBound ?? probe.length, probe.length)
    let count = Int(upper > lower ? upper - lower : 0)
    probe.note(
      count,
      requestedLower: range?.lowerBound ?? 0,
      requestedEnd: range?.upperBound ?? probe.length
    )
    consume(Data(count: count))
    return .success(())
  }
}

/// One stored ZIP entry, addressed the way `extractStoredRange` addresses it:
/// a seek to `entryOffset + range.lowerBound` on the archive's shared data
/// source. Production also puts Readium's CBC decryptor between the loader and
/// this, which reads the same span rounded out to a 16-byte block, so leaving
/// it out changes the byte counts here by less than a part in a thousand.
private final class StoredEntryResource: Resource {
  private let archive: Resource
  private let entryOffset: UInt64
  private let entryLength: UInt64
  private let lock = NSLock()
  private var _highestRequestedEnd: UInt64 = 0
  private var _lengthFailuresRemaining = 0

  /// Fails the next `count` length answers, as a flaky origin would.
  func failNextLengthAnswers(_ count: Int) {
    lock.withLock { _lengthFailuresRemaining = count }
  }

  /// Highest entry-relative upper bound asked of this entry, before it clamped.
  /// The shared archive buffer above reads ahead past an entry boundary quite
  /// legitimately — the archive is far larger than any entry — so an overshoot
  /// is only meaningful measured here.
  var highestRequestedEnd: UInt64 { lock.withLock { _highestRequestedEnd } }

  /// `servableLength` is what the archive will actually hand over, which
  /// PP-4542 says can be SHORTER than the length the LCP resource reports:
  /// ZIPFoundation throws `rangeOutOfBounds` once a range passes the entry's
  /// uncompressed size. Defaults to the reported length, so only a test that
  /// wants the mismatch sees one.
  init(
    archive: Resource,
    entryOffset: UInt64,
    entryLength: UInt64,
    servableLength: UInt64? = nil,
    cacheStore: ArchiveRangeStore? = nil
  ) {
    self.archive = archive
    self.entryOffset = entryOffset
    self.entryLength = entryLength
    self.servableLength = servableLength ?? entryLength
  }

  private let servableLength: UInt64

  let sourceURL: AbsoluteURL? = nil
  func properties() async -> ReadResult<ResourceProperties> { .success(ResourceProperties()) }
  func estimatedLength() async -> ReadResult<UInt64?> {
    let fail = lock.withLock { () -> Bool in
      guard _lengthFailuresRemaining > 0 else { return false }
      _lengthFailuresRemaining -= 1
      return true
    }
    if fail {
      return .failure(.access(.other(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))))
    }
    // Reads the tail through the archive, because `CBCLCPResource` has to:
    // the manifest carries no `originalLength`, so the plaintext size comes
    // from decrypting the final block. It is issued on the raw entry, so it
    // goes through the shared archive buffer at an offset far from wherever
    // the data reads are, and costs a whole fill. Answering it for free here
    // would leave every number in this file excluding its largest component.
    _ = await archive.stream(
      range: (entryOffset + entryLength - UInt64(Self.tailProbeLength))
        ..< (entryOffset + entryLength),
      consume: { _ in }
    )
    return .success(entryLength)
  }

  /// Enough to cover the final AES block plus the surrounding read; the exact
  /// size does not matter, only that the probe is a real read near the end.
  static let tailProbeLength = 8 * 1024

  func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
    lock.withLock {
      _highestRequestedEnd = max(_highestRequestedEnd, range?.upperBound ?? entryLength)
    }
    // The PP-4542 mismatch, reproduced: a range past what the entry can serve
    // fails rather than clamping itself, which is why the loader has to.
    if let range, range.upperBound > servableLength {
      return .failure(.access(.other(NSError(
        domain: "ReadiumZIPFoundation",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "rangeOutOfBounds"]
      ))))
    }
    let relativeLower = min(range?.lowerBound ?? 0, entryLength)
    let relativeUpper = min(range?.upperBound ?? entryLength, entryLength)
    guard relativeUpper > relativeLower else {
      consume(Data())
      return .success(())
    }
    return await archive.stream(
      range: (entryOffset + relativeLower) ..< (entryOffset + relativeUpper),
      consume: consume
    )
  }
}

/// The origin as an `HTTPClient`, counted by the same probe as the resource
/// origin so the two topologies are directly comparable.
private final class ProbeHTTPClient: HTTPClient, @unchecked Sendable {
  private let probe: ArchiveTransportProbe

  init(probe: ArchiveTransportProbe) { self.probe = probe }

  func stream(
    request: any HTTPRequestConvertible,
    consume: @escaping (Data, Double?) -> HTTPResult<Void>
  ) async -> HTTPResult<HTTPResponse> {
    guard case let .success(req) = request.httpRequest() else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    guard let header = req.headers["Range"],
          let spec = header.split(separator: "=").last,
          case let bounds = spec.split(separator: "-"),
          bounds.count == 2,
          let lower = UInt64(bounds[0]),
          let last = UInt64(bounds[1])
    else {
      return .failure(HTTPError.malformedResponse(nil))
    }
    let upper = min(last + 1, probe.length)
    let count = Int(upper > lower ? upper - lower : 0)
    probe.note(count, requestedLower: lower, requestedEnd: upper)
    if case let .failure(error) = consume(Data(count: count), 1.0) {
      return .failure(error)
    }
    return .success(HTTPResponse(
      request: req,
      url: req.url,
      status: HTTPStatus(rawValue: 206) ?? .ok,
      headers: [
        "Content-Range": "bytes \(lower)-\(upper - 1)/\(probe.length)",
        "Content-Length": "\(count)"
      ],
      mediaType: nil,
      body: nil
    ))
  }
}

/// Reads the archive through an `HTTPClient`, so a decorator on that client is
/// driven by exactly the reads Readium's archive buffer makes.
private final class HTTPArchiveResource: Resource {
  private let client: HTTPClient
  private let url: HTTPURL
  private let length: UInt64

  init(client: HTTPClient, url: HTTPURL, length: UInt64) {
    self.client = client
    self.url = url
    self.length = length
  }

  let sourceURL: AbsoluteURL? = nil
  func properties() async -> ReadResult<ResourceProperties> { .success(ResourceProperties()) }
  func estimatedLength() async -> ReadResult<UInt64?> { .success(length) }

  func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
    let lower = min(range?.lowerBound ?? 0, length)
    let upper = min(range?.upperBound ?? length, length)
    guard upper > lower else { return .success(()) }
    var req = HTTPRequest(url: url)
    req.setRange(lower ..< upper)
    let result = await client.stream(request: req) { data, _ in
      consume(data)
      return .success(())
    }
    switch result {
    case .success:
      return .success(())
    case let .failure(error):
      return .failure(.access(.http(error)))
    }
  }
}


/// Hands out one entry resource per track over a single shared buffered
/// archive, which is the topology `ZIPFoundationArchiveFactory` builds: one
/// `BufferingResource`, every entry reading through it.
private final class ArchiveContainer: Container, @unchecked Sendable {
  let tracks: [String: Resource]

  /// Builds the production topology: the origin, Readium's one shared archive
  /// buffer over it, then one stored entry per track. The per-track buffer the
  /// fix adds belongs to the loader, so it is not modelled here.
  init(
    probe: ArchiveTransportProbe,
    trackCount: Int,
    stride: UInt64,
    trackLength: UInt64,
    archiveBufferSize: Int,
    servableLength: UInt64? = nil,
    cacheStore: ArchiveRangeStore? = nil
  ) {
    // The origin, optionally with the app's byte-range cache between it and
    // Readium's archive buffer, which is where that cache sits in the app:
    // below the buffer, so it sees the buffer's own 6 MB fills.
    let origin: Resource
    if let cacheStore {
      origin = HTTPArchiveResource(
        client: PartialArchiveCachingHTTPClient(
          upstream: ProbeHTTPClient(probe: probe),
          storeFactory: { _, _ in cacheStore }
        ),
        url: HTTPURL(string: "https://origin.example/book.lcpa")!,
        length: probe.length
      )
    } else {
      origin = ArchiveResource(probe: probe)
    }
    let sharedArchive = origin.buffered(size: archiveBufferSize)
    var built: [String: Resource] = [:]
    for track in 0 ..< trackCount {
      let entry = StoredEntryResource(
        archive: sharedArchive,
        entryOffset: UInt64(track) * stride,
        entryLength: trackLength,
        servableLength: servableLength,
        cacheStore: cacheStore
      )
      built["track\(track).mp3"] = entry
    }
    tracks = built
  }

  let sourceURL: AbsoluteURL? = nil
  var entries: Set<AnyURL> { [] }

  subscript(url: any URLConvertible) -> Resource? {
    let path = url.anyURL.string
    return tracks.first { path.hasSuffix($0.key) }?.value
  }
}

private final class ArchiveProvider: StreamingResourceProvider, @unchecked Sendable {
  private let publication: Publication
  private let container: ArchiveContainer

  init(
    probe: ArchiveTransportProbe,
    trackCount: Int,
    stride: UInt64,
    trackLength: UInt64,
    archiveBufferSize: Int,
    servableLength: UInt64? = nil,
    cacheStore: ArchiveRangeStore? = nil
  ) {
    let container = ArchiveContainer(
      probe: probe,
      trackCount: trackCount,
      stride: stride,
      trackLength: trackLength,
      archiveBufferSize: archiveBufferSize,
      servableLength: servableLength,
      cacheStore: cacheStore
    )
    self.container = container
    publication = Publication(
      manifest: Manifest(
        metadata: Metadata(title: "egress"),
        readingOrder: (0 ..< trackCount).map { Link(href: "track\($0).mp3", mediaType: .mp3) }
      ),
      container: container
    )
  }

  /// Withholds the publication until this date, modelling an open that has to
  /// go to the network: asset retrieval, licence validation, then the remote
  /// archive's central directory.
  var availableFrom: Date?

  func getPublication() -> Publication? {
    if let availableFrom, Date() < availableFrom { return nil }
    return publication
  }

  var isLocalFile = false
  func archiveIsLocalFile() -> Bool { isLocalFile }

  // Required without a default so no conformer can silently skip them; this
  // fake measures egress, not the yield behaviour.
  func streamingLoadDidBegin() {}
  func streamingLoadDidEnd() {}

  /// The entry behind a track, for tests that assert on what it was asked for.
  func entry(forTrack track: Int) -> StoredEntryResource? {
    container.tracks["track\(track).mp3"] as? StoredEntryResource
  }
}

/// A request that never ends is a failure, not a skip: the amplification
/// numbers are only meaningful if every segment was actually answered.
private struct RequestNeverFinished: Error {
  let timeout: TimeInterval
}

/// Records the bytes a loading request was answered with, and when it ended.
private final class RecordingRequest: LCPStreamingLoadingRequest, @unchecked Sendable {
  enum Outcome: Equatable {
    case success
    case failure(String)
  }

  let requestURL: URL?
  let needsContentInformation: Bool
  let requestedRange: LCPRequestedRange?
  /// Fires on the first byte handed back, which is when audio can start.
  var onFirstRespond: (() -> Void)?
  private var hasResponded = false

  private let lock = NSLock()
  private var _respondedBytes = 0
  private var _outcome: Outcome?
  private var waiters: [CheckedContinuation<Outcome, Never>] = []

  init(url: URL, range: LCPRequestedRange?, needsContentInformation: Bool = false) {
    requestURL = url
    requestedRange = range
    self.needsContentInformation = needsContentInformation
  }

  var respondedBytes: Int { lock.withLock { _respondedBytes } }

  func provideContentInformation(contentType: String, contentLength: Int64?) {}

  func respond(with data: Data) {
    let isFirst: Bool = lock.withLock {
      _respondedBytes += data.count
      defer { hasResponded = true }
      return !hasResponded && !data.isEmpty
    }
    if isFirst { onFirstRespond?() }
  }

  func finishLoading() { finish(.success) }

  func finishLoading(with error: Error?) {
    finish(error.map { .failure(String(describing: $0)) } ?? .success)
  }

  private func finish(_ outcome: Outcome) {
    let waiting: [CheckedContinuation<Outcome, Never>] = lock.withLock {
      guard _outcome == nil else { return [] }
      _outcome = outcome
      defer { waiters.removeAll() }
      return waiters
    }
    waiting.forEach { $0.resume(returning: outcome) }
  }

  func waitUntilFinished(timeout: TimeInterval) async throws -> Outcome {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let outcome = lock.withLock({ _outcome }) {
        return outcome
      }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw RequestNeverFinished(timeout: timeout)
  }
}
