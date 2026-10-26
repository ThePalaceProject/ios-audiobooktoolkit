import AVFoundation
import Foundation
import ReadiumShared
import UniformTypeIdentifiers

// MARK: - LCPResourceLoaderDelegate

final class LCPResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
  weak var provider: StreamingResourceProvider?
  private let maxConcurrentRequests = 8
  /// How long a data transfer may go without delivering a byte before the
  /// request is failed with `LCPResourceLoaderError.transferStalled`.
  ///
  /// This bounds INACTIVITY in the data phase only. It deliberately does not
  /// apply while a request waits on a track's length (see `serve`), and it sits
  /// above the 60 s idle timeout of the `URLSessionConfiguration.default`
  /// sessions Readium's `DefaultHTTPClient` uses, so a network stall surfaces as
  /// the transport's own error, with its real cause, before this fires.
  private let stallTimeout: TimeInterval
  private let inflightQueue = DispatchQueue(label: "com.palace.lcp-streaming.inflight", attributes: .concurrent)
  private var inflightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

  /// The track each serve now in its byte-transfer phase is reading, most
  /// recently started first.
  ///
  /// Separate from `inflightTasks` because a serve's href is not known until
  /// the reading order has been consulted, which happens after registration.
  /// Guarded by `inflightQueue` like the tasks it refers to.
  private var transferringTracks: [(id: ObjectIdentifier, href: String)] = []
  private let concurrencySemaphore = DispatchSemaphore(value: 8)

  /// Total decrypted bytes this loader has handed to AVFoundation, across every
  /// request it has served.
  ///
  /// Monotonic and never reset, so a reader only has to compare two samples: a
  /// higher number means bytes arrived in between. `LCPStreamingPlayer` samples
  /// it to tell a slow load from a stalled one — the publication load timeout
  /// used to fail both, and a cross-chapter seek competing with the background
  /// package fetch is the slow case (PP-5367).
  private let servedByteCount = LockIsolated(0)

  var bytesServed: Int { servedByteCount.value }

  /// The chapter load being timed, so a start can be reported as the two
  /// intervals a patron actually experiences: how long until the first byte
  /// reached AVFoundation, and how long until audio came out.
  ///
  /// One at a time. A new chapter load supersedes the old; the old one's
  /// timings are already reported or lost with it.
  private let chapterLoad = LockIsolated<ChapterLoadMark?>(nil)

  struct ChapterLoadMark: Equatable, Sendable {
    let startedAt: Date
    let bytesAtStart: Int
    var firstByteAt: Date?
  }

  var chapterLoadMark: ChapterLoadMark? { chapterLoad.value }

  func markChapterLoadStart(at date: Date = Date()) {
    chapterLoad.value = ChapterLoadMark(
      startedAt: date,
      bytesAtStart: servedByteCount.value,
      firstByteAt: nil
    )
  }

  /// What the loader was asked for one track, and how much of it failed.
  struct LoaderActivity: Equatable {
    var received: Int
    var failed: Int
  }

  /// Loading requests handed over per track, and the ones that ended in an
  /// error.
  ///
  /// `bytesServed` cannot tell a loader that is serving nothing from a loader
  /// nothing has asked, because both read zero, and the player's load timeout
  /// decides whether to fail a chapter on that difference. The failure count
  /// separates the other pair that reads alike: a request failing in
  /// milliseconds, repeatedly, costs the same chapter as one transfer that
  /// stalls.
  private let requestActivityByHref = LockIsolated<[String: LoaderActivity]>([:])

  /// What was asked for `href`, in the spelling the player builds the item's
  /// URL from.
  func loadingRequests(forHref href: String) -> LoaderActivity {
    requestActivityByHref.value[href] ?? LoaderActivity(received: 0, failed: 0)
  }

  /// The href each track's items read, as the player built their URLs.
  ///
  /// Recorded where the track and the URL are both in hand, so the key a
  /// caller asks with and the key the requests are counted under cannot drift.
  /// Deriving the href from the reading order instead would be a second
  /// expression for the same fact, and one of them is percent-decoded.
  private let hrefByTrackKey = LockIsolated<[String: String]>([:])

  func noteTrack(key trackKey: String, servesHref href: String) {
    hrefByTrackKey.withValue { $0[trackKey] = href }
  }

  /// What was asked for the track `trackKey`, or nil when no item for it has
  /// been built through this loader — which is unknown, not none.
  func loadingRequests(forTrackKey trackKey: String) -> LoaderActivity? {
    guard let href = hrefByTrackKey.value[trackKey] else { return nil }
    return loadingRequests(forHref: href)
  }

  /// The track a request names, taken from the URL rather than the reading
  /// order: a caller asking why nothing was served has to be told about
  /// requests that never reached `serve` either.
  static func requestedHref(for url: URL) -> String {
    let path = url.path
    return path.hasPrefix("/") ? String(path.dropFirst()) : path
  }

  /// How long a chapter waits for a resolution already running to reach its
  /// track before it falls back to Readium's probe.
  ///
  /// The resolution takes the track a chapter is waiting on first and needs two
  /// small reads for it, measured at about 0.8s each on device. The probe it
  /// falls back to cost 10.9-18.3s and 18.6 MB in the same measurement, so a
  /// wait of this length is worth taking and its worst case is no worse than
  /// what it replaces.
  static let lengthWaitTimeout: TimeInterval = 6

  /// A chapter change slower than this is what a patron reports as a book that
  /// will not start, so it is worth a line in the log they can export.
  static let slowChapterServeThreshold: TimeInterval = 1.5

  /// How many serve reports the loader keeps. A diagnostic tail, long enough to
  /// cover the player's prefetch window and the chapter the patron left.
  static let maxRetainedServeReports = 16

  /// What each recent chapter serve asked for and what it cost, oldest first.
  ///
  /// Held as values rather than written only to the log so the behaviour can be
  /// stated without an AVFoundation load, and so a reader of a slow chapter
  /// change has the superseded serves beside the one the patron is waiting for.
  let serveReports = LockIsolated<[ServeReport]>([])

  /// One chapter serve, as the exported log reports it.
  struct ServeReport: Equatable {
    /// The track's href, or the URL's last component when the serve ended
    /// before the reading order was consulted.
    let href: String
    /// What AVFoundation asked for, or nil for a content-information request.
    let range: LCPRequestedRange?
    let elapsed: TimeInterval
    /// When the track's plaintext length resolved, relative to the serve's
    /// start, or nil if it never did.
    let lengthProbe: TimeInterval?
    let originRequests: Int
    let originBytes: Int
    /// Bytes THIS serve handed to AVFoundation.
    let deliveredBytes: Int
    let wasCancelled: Bool
    /// Why the serve ended the request with an error, or nil when it did not.
    let failure: String?

    /// Worth a line in the exported log.
    ///
    /// A fast successful serve is one a patron would not notice, and a line per
    /// segment read would bury the ones they would. A serve that failed or was
    /// cancelled costs the chapter whatever it cost in time — a failed item is
    /// pushed onto the streaming path and the queue rebuilt — so the duration
    /// is not what decides it.
    var isWorthALogLine: Bool {
      failure != nil || wasCancelled
        || elapsed >= LCPResourceLoaderDelegate.slowChapterServeThreshold
    }

    /// What AVFoundation asked this serve for, in the terms the request used.
    var askedFor: String {
      guard let range else { return "content information" }
      return range.toEnd
        ? "the bytes from \(range.offset) to the end"
        : "\(range.length) bytes from \(range.offset)"
    }

    /// The origin figures are a delta over this serve's own lifetime, and
    /// serves overlap, so concurrent serves each count the traffic that flowed
    /// while they ran. They are not additive across lines; the delivered count
    /// is this serve's alone.
    var description: String {
      String(
        format: "LCP chapter serve took %.1fs (length probe %@) for %@, which asked for %@; delivered %d bytes; archive origin cost %d request(s) / %d bytes while it ran; %@",
        elapsed,
        lengthProbe.map { String(format: "%.1fs", $0) } ?? "never",
        href.isEmpty ? "an unnamed track" : href,
        askedFor,
        deliveredBytes,
        originRequests,
        originBytes,
        failure.map { "failed: \($0)" } ?? (wasCancelled ? "cancelled" : "finished")
      )
    }
  }

  private func record(_ report: ServeReport) {
    serveReports.withValue {
      $0.append(report)
      $0 = Array($0.suffix(Self.maxRetainedServeReports))
    }
  }



  /// Resolved, buffered resource per track href, least-recently-used first.
  ///
  /// Readium gives a ZIP it reads over HTTP a single buffer shared by every
  /// entry (`ZIPFoundationArchiveFactory`), and documents it as ignored when
  /// reading backward or far ahead. The player keeps a window of tracks open at
  /// widely separated offsets in the archive, so their reads displace each
  /// other and every displaced read pays for a whole fill. Measured at 48x the
  /// bytes served — the archive buffer divided by this loader's segment.
  ///
  /// A buffer per track absorbs that: a track's reads come out of its own
  /// window, so one archive fill is consumed in full before another track can
  /// displace it. It has to be reused across loading requests to work at all,
  /// because each request otherwise resolves a fresh resource with an empty
  /// buffer, which is why this is a cache and not a local.
  /// Typed as the concrete buffer rather than `any Resource`: `Resource` is not
  /// `Sendable`, so an existential here draws a Sendable diagnostic on every
  /// read of the store. `BufferingResource` is an actor, so it is.
  private let bufferedTracks = LockIsolated<[(href: String, task: Task<TrackEntry?, Never>)]>([])

  /// Per-track buffer size, and how many tracks are buffered at once.
  ///
  /// The size must be at least Readium's archive buffer or a proportional
  /// refetch remains, because a per-track fill smaller than an archive fill
  /// cannot consume one before another track displaces it. It is a copy of a
  /// constant private to Readium (`ZIPFoundationArchiveFactory`'s `6.MB`); a
  /// toolkit bump that changes that value silently degrades this, and no test
  /// catches it, because the sweeps inject their own archive buffer rather than
  /// reading Readium's.
  ///
  /// The count has to cover every track read together. A rebuild enqueues one
  /// item (`LCPStreamingPlayer.queueWindow`), and the chapter after it is
  /// preloaded once playback has started (`followingChapterIndex`), so steady
  /// playback reads two. A seek or a track boundary leaves the pair it
  /// supersedes draining while the new pair is built, which is four hrefs
  /// inside one episode and the widest set the player can produce — and a
  /// patron who seeks back to where they were needs the first of those still
  /// resident. Four is therefore the bound, twice the steady-state pair.
  ///
  /// A smaller count does not reduce the refetch, it loses the whole benefit:
  /// reads arriving round-robin over more tracks than are buffered evict the
  /// entry needed next, so the hit rate is zero. For a fixed memory budget a
  /// larger count therefore beats a larger size. Three is measurably worse
  /// over the same episode, which is why the bound is not lowered further.
  ///
  /// The count is a cap, not an allocation: a buffer exists only for a track
  /// that has been read, so four is at most 24 MB retained, not reserved.
  /// `LCPStreamingEgressTests` measures both relationships.
  ///
  /// Named so the egress measurement exercises the shipped values rather than
  /// restating them, which would let the two drift apart silently.
  static let defaultPerTrackBufferSize = 6 * 1024 * 1024
  static let defaultMaxBufferedTracks = 4

  private let perTrackBufferSize: Int
  private let maxBufferedTracks: Int
  private let publicationWaitTimeout: TimeInterval

  init(
    provider: StreamingResourceProvider? = nil,
    stallTimeout: TimeInterval = 90,
    perTrackBufferSize: Int = LCPResourceLoaderDelegate.defaultPerTrackBufferSize,
    maxBufferedTracks: Int = LCPResourceLoaderDelegate.defaultMaxBufferedTracks,
    publicationWaitTimeout: TimeInterval = LCPResourceLoaderDelegate.defaultPublicationWaitTimeout
  ) {
    self.provider = provider
    self.stallTimeout = stallTimeout
    self.perTrackBufferSize = perTrackBufferSize
    self.maxBufferedTracks = maxBufferedTracks
    self.publicationWaitTimeout = publicationWaitTimeout
    super.init()
  }

  /// Stops every request this loader is serving without finishing it. For
  /// teardown only: a request AVFoundation is still waiting on stays unanswered.
  func cancelAllRequests() {
    inflightQueue.sync {
      inflightTasks.values.forEach { $0.cancel() }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks.removeAll()
      self?.transferringTracks.removeAll()
    }
  }

  func clearCaches() {
    bufferedTracks.value = []
  }

  /// Records that a serve has entered its byte-transfer phase, and abandons the
  /// serves for tracks that have fallen outside the buffered window.
  ///
  /// Abandoning means cancelling without finishing, which is what `didCancel`
  /// already does: a request AVFoundation has moved off needs no answer, and
  /// failing it would risk dead-ending an item the patron may return to.
  private func beginTransfer(id: ObjectIdentifier, href: String) {
    let stale: [(id: ObjectIdentifier, href: String)] = inflightQueue.sync(flags: .barrier) {
      transferringTracks.removeAll { $0.id == id }
      transferringTracks.insert((id: id, href: href), at: 0)

      let abandon = Set(TrackServeWindow.hrefsToAbandon(
        recencyOrder: transferringTracks.map(\.href),
        window: maxBufferedTracks
      ))
      guard !abandon.isEmpty else { return [] }

      let outside = transferringTracks.filter { abandon.contains($0.href) }
      transferringTracks.removeAll { abandon.contains($0.href) }
      return outside
    }

    guard !stale.isEmpty else { return }
    let abandonedHrefs = Set(stale.map(\.href))
    ATLog(
      .info,
      "🎵 ResourceLoader: abandoning \(stale.count) serve(s) for \(abandonedHrefs.count) track(s) outside the \(maxBufferedTracks)-track window"
    )
    inflightQueue.sync {
      for entry in stale {
        inflightTasks[entry.id]?.cancel()
      }
    }
  }

  /// Drops a finished transfer from the window.
  private func endTransfer(id: ObjectIdentifier) {
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.transferringTracks.removeAll { $0.id == id }
    }
  }

  /// The object that owns the in-flight requests and caches cancels them.
  /// Previously only `LCPStreamingPlayer.deinit` called `shutdown()`, and that
  /// cross-object reach from a deinit is what the isolation made illegal.
  deinit {
    inflightTasks.values.forEach { $0.cancel() }
  }

  func shutdown() {
    cancelAllRequests()
    clearCaches()
    provider = nil
  }

  func resourceLoader(
    _: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    shouldWait(for: loadingRequest)
  }

  func resourceLoader(
    _: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    didCancel(loadingRequest)
  }

  func shouldWait(for loadingRequest: LCPStreamingLoadingRequest) -> Bool {
    guard let url = loadingRequest.requestURL else {
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Missing URL"]
      ))
      return false
    }

    let isValidScheme = (url.scheme == "fake" && url.host == "lcp-streaming") ||
      (url.scheme == "readium-lcp")

    guard isValidScheme else {
      ATLog(.error, "🎵 ResourceLoader: Invalid URL scheme: \(url.absoluteString)")
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid URL scheme"]
      ))
      return false
    }

    // Counted here rather than in `serve`: what the player asks is whether
    // anything ever asked the loader for a track, which includes a request
    // that never reached a serve at all.
    requestActivityByHref.withValue {
      $0[Self.requestedHref(for: url), default: LoaderActivity(received: 0, failed: 0)].received += 1
    }

    if let publication = provider?.getPublication() {
      startServing(loadingRequest: loadingRequest, with: publication)
      return true
    }

    // The publication is not open yet, which is the normal state on a first
    // open: it is retrieved over the network, its licence validated, and its
    // central directory read before it exists. So the request waits for it.
    //
    // It used to wait 0.8 s on this thread with `Thread.sleep` and then fail
    // the request. Nothing recovered from that: the player has already built
    // its items, and `publicationDidLoad` rebuilds only when the queue is
    // EMPTY, so the failed items stayed, `isLoaded` never flipped, and the
    // player's 30 s guard reported "Timed out waiting for LCP publication to
    // load" and closed the book. A second open worked because the publication
    // was cached by then, which is why this only showed on a first open.
    awaitPublicationThenServe(loadingRequest)
    return true
  }

  /// Serves `loadingRequest` once the publication exists, or fails it if it
  /// never does.
  ///
  /// Suspends rather than blocking: this runs on whatever thread AVFoundation
  /// calls the delegate on, and holding that thread stalls every other request
  /// it is trying to hand over. No concurrency slot is taken while waiting —
  /// `startServing` acquires one, and only once there is something to serve.
  ///
  /// Polling because the publication's arrival is not something this object is
  /// told about; the player receives `publicationDidLoad`. Being signalled
  /// instead of polling would be better, and is the shape to move to if this
  /// needs to get cheaper.
  private func awaitPublicationThenServe(_ loadingRequest: LCPStreamingLoadingRequest) {
    let id = ObjectIdentifier(loadingRequest)
    let waitTask = Task { [weak self, weak loadingRequest] in
      let deadline = Date().addingTimeInterval(self?.publicationWaitTimeout
        ?? Self.defaultPublicationWaitTimeout)
      while Date() < deadline {
        if Task.isCancelled { return }
        // AVFoundation has let go of the request, so there is nobody to serve.
        guard let loadingRequest else { return }
        if let self, let publication = self.provider?.getPublication() {
          self.inflightQueue.async(flags: .barrier) { [weak self] in
            self?.inflightTasks.removeValue(forKey: id)
          }
          self.startServing(loadingRequest: loadingRequest, with: publication)
          return
        }
        try? await Task.sleep(nanoseconds: Self.publicationPollInterval)
      }
      guard let loadingRequest, !Task.isCancelled else { return }
      ATLog(.warn, "🎵 ResourceLoader: publication never opened — failing the request")
      loadingRequest.finishLoading(with: NSError(
        domain: "LCPResourceLoader",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Publication not available for streaming"]
      ))
    }
    // Registered so `didCancel` and `shutdown` reach a request that is still
    // waiting, not only one already being served.
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks[id] = waitTask
    }
  }

  /// Long enough for a publication to open over a slow connection, and shorter
  /// than the player's own 30 s guard so a genuine failure is reported by the
  /// loader rather than by a timer that cannot say what went wrong.
  static let defaultPublicationWaitTimeout: TimeInterval = 25
  private static let publicationPollInterval: UInt64 = 50_000_000

  /// AVFoundation no longer needs this request. Its task — length lookup and
  /// byte transfer alike — stops, and the request is left unfinished, as the
  /// cancellation contract requires.
  func didCancel(_ loadingRequest: LCPStreamingLoadingRequest) {
    let id = ObjectIdentifier(loadingRequest)
    inflightQueue.sync {
      inflightTasks[id]?.cancel()
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks.removeValue(forKey: id)
    }
  }
}

// MARK: - Loading-request seam

/// The parts of `AVAssetResourceLoadingRequest` the loader uses.
///
/// AVFoundation offers no way to construct a loading request outside a real
/// asset load, so the serving logic is written against this protocol and the
/// tests drive it with a recording fake. `AVAssetResourceLoadingRequest` is the
/// only production conformer.
protocol LCPStreamingLoadingRequest: AnyObject {
  var requestURL: URL? { get }
  /// True when AVFoundation asked for the content type and length.
  var needsContentInformation: Bool { get }
  /// The byte range AVFoundation asked for, or nil for a content-information-only request.
  var requestedRange: LCPRequestedRange? { get }
  func provideContentInformation(contentType: String, contentLength: Int64?)
  func respond(with data: Data)
  func finishLoading()
  func finishLoading(with error: Error?)
}

struct LCPRequestedRange: Equatable {
  let offset: Int64
  let length: Int
  let toEnd: Bool
}

extension AVAssetResourceLoadingRequest: LCPStreamingLoadingRequest {
  var requestURL: URL? { request.url }

  var needsContentInformation: Bool { contentInformationRequest != nil }

  var requestedRange: LCPRequestedRange? {
    dataRequest.map {
      LCPRequestedRange(
        offset: $0.requestedOffset,
        length: $0.requestedLength,
        toEnd: $0.requestsAllDataToEndOfResource
      )
    }
  }

  func provideContentInformation(contentType: String, contentLength: Int64?) {
    guard let info = contentInformationRequest else { return }
    info.contentType = contentType
    info.isByteRangeAccessSupported = true
    if let contentLength {
      info.contentLength = contentLength
    }
  }

  func respond(with data: Data) {
    dataRequest?.respond(with: data)
  }
}

// MARK: - Helpers

private extension LCPResourceLoaderDelegate {
  func startServing(loadingRequest: LCPStreamingLoadingRequest, with publication: Publication) {
    let id = ObjectIdentifier(loadingRequest)
    // The slot holds the semaphore itself, not the loader, so it can still be
    // signalled after the last reference to the loader goes away. A semaphore
    // disposed below its initial value traps in libdispatch.
    let slot = RequestSlot(concurrencySemaphore)
    slot.acquire()
    let serveTask = Task { [weak self, weak loadingRequest] in
      defer { slot.release() }
      guard let self, let loadingRequest else {
        return
      }
      await serve(loadingRequest: loadingRequest, with: publication, slot: slot)
      inflightQueue.async(flags: .barrier) { [weak self] in
        self?.inflightTasks.removeValue(forKey: id)
      }
    }
    inflightQueue.async(flags: .barrier) { [weak self] in
      self?.inflightTasks[id] = serveTask
    }
  }


  func serve(loadingRequest: LCPStreamingLoadingRequest, with pub: Publication, slot: RequestSlot) async {
    let request = FinishOnce(loadingRequest)
    let serveStartedAt = Date()
    // Keyed the way the player will ask for it, and read before the reading
    // order is consulted so a serve that never gets there still counts against
    // the right track.
    let requestHref = loadingRequest.requestURL.map(Self.requestedHref(for:)) ?? ""
    let originBefore = provider?.archiveOriginActivity() ?? (requests: 0, bytes: 0)
    // Read here rather than in the report: the report is written from a `defer`
    // that can run after AVFoundation has dropped the request.
    let requestedRange = loadingRequest.requestedRange
    // The track the URL names, so a serve that ends before the reading order is
    // consulted still says which file it was for. Replaced by the resolved href
    // once there is one.
    let servedHref = LockIsolated(loadingRequest.requestURL?.lastPathComponent ?? "")
    // Bytes THIS serve handed over. `servedByteCount` is loader-wide, so its
    // delta over a serve's lifetime includes whatever other chapters delivered
    // while it ran, and a chapter the patron has left then reads as busy.
    let deliveredBytes = LockIsolated(0)
    // `lengthResolvedAt` separates the two halves of a cold chapter: Readium
    // must read the entry's CBC tail to learn the plaintext length before any
    // audio byte can be asked for, and that probe sits at the far end of the
    // entry from the audio. Reported from a `defer` so a cancelled or failed
    // serve is measured too — the slow cases are the ones that do not finish.
    let lengthResolvedAt = LockIsolated<Date?>(nil)
    defer {
      let after = provider?.archiveOriginActivity() ?? (requests: 0, bytes: 0)
      let report = ServeReport(
        href: servedHref.value,
        range: requestedRange,
        elapsed: Date().timeIntervalSince(serveStartedAt),
        lengthProbe: lengthResolvedAt.value.map { $0.timeIntervalSince(serveStartedAt) },
        originRequests: after.requests - originBefore.requests,
        originBytes: after.bytes - originBefore.bytes,
        deliveredBytes: deliveredBytes.value,
        wasCancelled: Task.isCancelled,
        failure: request.failure
      )
      record(report)
      if request.failure != nil {
        requestActivityByHref.withValue {
          $0[requestHref, default: LoaderActivity(received: 0, failed: 0)].failed += 1
        }
      }
      if report.isWorthALogLine {
        ATLog(.error, report.description)
      }
    }
    guard let url = loadingRequest.requestURL else {
      request.fail(NSError(
        domain: "LCPResourceLoader", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing URL"]
      ))
      return
    }

    var trackIndex = 0
    var href = ""

    if url.scheme == "readium-lcp" {
      let host = url.host ?? ""
      let pathComponents = url.pathComponents.filter { $0 != "/" }

      if host.hasPrefix("track"),
         let indexStr = String(host.dropFirst(5)).components(separatedBy: CharacterSet.decimalDigits.inverted).first,
         let index = Int(indexStr)
      {
        trackIndex = index
        href = pathComponents.first ?? ""
        ATLog(.debug, "Using fallback track path: \(href)")
      }
    } else if url.scheme == "fake" && url.host == "lcp-streaming" {
      let comps = url.pathComponents
      trackIndex = (comps.count >= 3 && comps[1] == "track") ? Int(comps[2]) ?? 0 : 0
      href = url.lastPathComponent
    }

    var link: Link?

    if trackIndex < pub.readingOrder.count {
      link = pub.readingOrder[trackIndex]
      ATLog(.debug, "Found reading order item for track: \(href)")
    } else {
      link = pub.readingOrder.first { $0.href.contains(href) }
    }

    guard let validLink = link else {
      request.fail(NSError(
        domain: "LCPResourceLoader",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Track not found in reading order"]
      ))
      return
    }

    let finalHref = validLink.href.components(separatedBy: "#").first ?? validLink.href
    servedHref.value = finalHref
    let resolvedEntry = await trackEntry(for: pub, href: finalHref)
    lengthResolvedAt.withValue { $0 = Date() }
    guard case let .some(entry) = resolvedEntry else {
      return // cancelled
    }

    let trackLength = entry?.length

    // With no entry this request reads unbuffered rather than being refused.
    // A CBC read still needs the length, so it succeeds only if Readium's own
    // tail fetch now does; the next request builds a fresh entry either way.
    let readSource: Resource? = entry?.buffer
      ?? Self.resource(for: pub, href: finalHref, knownLength: trackLength)

    // Content-information phase. No timer runs here: the length lookup is a
    // network round trip for CBC resources, and a fixed timer at this point
    // failed requests whose lookup was still in progress (PP-5240). It ends
    // when the transport reports success or its own error, or when AVFoundation
    // cancels the request.
    if loadingRequest.needsContentInformation {
      let contentType = Self.utiIdentifier(forHref: finalHref, fallbackMime: validLink.mediaType?.string)
      loadingRequest.provideContentInformation(
        contentType: contentType,
        contentLength: trackLength.map { Int64($0) }
      )
    }

    guard let range = loadingRequest.requestedRange else {
      request.succeed()
      return
    }

    guard let readSource else {
      ATLog(.error, "🎵 ResourceLoader: No resource available for streaming")
      request.fail(NSError(
        domain: "LCPResourceLoader", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "No resource available for streaming"]
      ))
      return
    }

    // The concurrency limit admits requests into the lookup phase; a transfer
    // gives its slot back so a long read cannot hold the resource-loader queue.
    slot.release()

    // The slot above admits requests into the lookup phase only, so nothing
    // bounded how many transfers ran at once. The loader buffers
    // `maxBufferedTracks` tracks, and reads spread wider than that evict the
    // window needed next, so a skip burst both thrashed the buffers and left
    // the chapter the patron waited for competing with chapters they had
    // already left (PP-5398).
    let serveID = ObjectIdentifier(loadingRequest)
    beginTransfer(id: serveID, href: finalHref)
    defer { endTransfer(id: serveID) }

    let start = max(0, Int(range.offset))
    var count = range.length
    if count == 0 && range.toEnd {
      count = trackLength.map { max(0, Int($0) - start) } ?? Int.max
    }

    // The buffer serves the fast path; the clamp needs the raw resource, so a
    // length/size mismatch can still find the real end (PP-4542).
    await transfer(
      from: readSource,
      clampTrack: entry?.buffer == nil ? nil : (publication: pub, href: finalHref, length: trackLength),
      start: start,
      count: count,
      to: request,
      delivered: deliveredBytes
    )
  }

  /// Reads `count` bytes from `start` into the request, failing it with
  /// `transferStalled` if `stallTimeout` passes with no bytes delivered. Stops without finishing
  /// when the serving task is cancelled.
  /// `makeClampSource` yields the UNBUFFERED resource for the same track, used
  /// only on the out-of-bounds path; see `readClampedToAvailable`. A factory
  /// rather than a resource because the overshoot is rare and resolving one
  /// per request would cost every well-formed read a container lookup it never
  /// uses.
  /// `delivered` accumulates what THIS transfer handed over, which is what the
  /// serve report states; the loader-wide counter cannot answer for one serve.
  func transfer(
    from resource: Resource,
    clampTrack: (publication: Publication, href: String, length: UInt64?)? = nil,
    start: Int,
    count: Int,
    to request: FinishOnce,
    delivered: LockIsolated<Int>
  ) async {
    let lastProgress = LockIsolated(Date())
    let stallTimeout = stallTimeout
    // Captured rather than reached through `self`: the box is `Sendable`, the
    // loader is not, so touching `self` inside the task below draws a
    // concurrency diagnostic.
    let servedByteCount = servedByteCount
    // Captured like the counter above: the box is Sendable, the loader is not.
    let chapterLoad = chapterLoad

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          // Resolved on first use and reused, so an overshoot costs one
          // lookup however many probes the search takes, and a read that
          // never overshoots costs none. A local function, not a stored
          // closure: it captures a mutable local and stays non-escaping.
          var resolvedClampSource: Resource??
          func clampRead(_ range: Range<UInt64>) async throws -> Data {
            if resolvedClampSource == nil {
              resolvedClampSource = .some(
                clampTrack.flatMap { Self.resource(for: $0.publication, href: $0.href, knownLength: $0.length) }
              )
            }
            guard let raw = resolvedClampSource.flatMap({ $0 }) else {
              return try await resource.read(range: range).get()
            }
            return try await raw.read(range: range).get()
          }
          let segmentSize = 128 * 1024
          var bytesRemaining = count
          var currentStart = start
          var totalBytesRead = 0
          while bytesRemaining > 0 {
            let thisCount = bytesRemaining == Int.max ? segmentSize : min(bytesRemaining, segmentSize)
            let endExcl = currentStart + thisCount
            // PP-4542: tolerate a length/size mismatch instead of failing the
            // AVPlayerItem. Readium 3.9.0's LCP resource can report a length
            // larger than ZIPFoundation will serve — extractRange throws
            // rangeOutOfBounds when a range's upperBound exceeds the ZIP entry's
            // uncompressedSize. AVPlayer's first-open TAIL probe (it reads the
            // last bytes for mp3 duration/metadata) then overshoots and the item
            // dead-ends ("Audiobook Unavailable"). CLAMP the read to the largest
            // readable prefix and finish SUCCESSFULLY, so AVPlayer gets the real
            // tail bytes and plays.
            let (data, reachedEOF) = try await LCPResourceLoaderDelegate.readClampedToAvailable(
              start: UInt64(currentStart),
              requestedEnd: UInt64(endExcl),
              probe: clampRead
            ) { try await resource.read(range: $0).get() }
            if Task.isCancelled { return }
            if !data.isEmpty {
              request.respond(with: data)
              lastProgress.value = Date()
              servedByteCount.withValue { $0 += data.count }
              delivered.withValue { $0 += data.count }
              chapterLoad.withValue { mark in
                guard mark != nil, mark?.firstByteAt == nil else { return }
                mark?.firstByteAt = Date()
              }
              totalBytesRead += data.count
              if bytesRemaining != Int.max {
                bytesRemaining -= data.count
              }
              currentStart += data.count
            }
            if reachedEOF || data.isEmpty {
              break
            }
          }
          ATLog(.debug, "🎵 ResourceLoader: Successfully loaded \(totalBytesRead) bytes (decrypted)")
          request.succeed()
        } catch {
          if Task.isCancelled { return }
          ATLog(.error, "🎵 ResourceLoader: ERROR loading data (after cold-load retries): \(error)")
          request.fail(error)
        }
      }

      group.addTask {
        while true {
          let idle = Date().timeIntervalSince(lastProgress.value)
          if idle >= stallTimeout {
            ATLog(.warn, "🎵 ResourceLoader: no bytes for \(Int(idle)) s — failing the request")
            request.fail(LCPResourceLoaderError.transferStalled)
            return
          }
          do {
            try await Task.sleep(nanoseconds: UInt64((stallTimeout - idle) * 1_000_000_000))
          } catch {
            return // cancelled
          }
        }
      }

      // Whichever ends first decides; the other is cancelled. A read that
      // ignores cancellation keeps this task alive, but the request has
      // already been answered and the slot released.
      await group.next()
      group.cancelAll()
    }
  }

  /// `task.value`, or nil as soon as the CALLING task is cancelled.
  ///
  /// Awaiting `Task.value` does not observe the waiter's cancellation, and
  /// Readium's CBC length lookup runs in an unstructured task of its own, so a
  /// cancelled request would otherwise stay parked — holding its concurrency
  /// slot — until a lookup it no longer wants finished.
  static func value<T: Sendable>(of task: Task<T, Never>) async -> T? {
    let gate = ResumeOnce<T?>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        gate.install(continuation)
        Task { gate.resume(with: await task.value) }
      }
    } onCancel: {
      gate.resume(with: nil)
    }
  }

  /// Everything the loader needs for a track, resolved once and kept in one
  /// place: the buffer reads come from, and the decrypted length those reads
  /// and the content-information phase are answered with.
  ///
  /// One store, deliberately. The length reaches readers through Readium's
  /// per-instance lazy task, its buffer's own memo, and this loader; holding
  /// it in several places keyed differently is what produced a run of
  /// coherence defects — a cold cache memoized as "unknown", an instance
  /// reached untouched on a cache hit, a failure cached and never retried.
  /// With a single entry per track there is no second store to disagree with.
  ///
  /// The entry is a task so the work happens once even under concurrent
  /// requests, and so the length is resolved BEFORE any read: Readium learns
  /// it in a `lazy var` that a read touches as well (`CBCLCPResource.stream`
  /// awaits `plainTextSizeTask`, swift-toolkit 58413f8), and `BufferingResource`
  /// is reentrant, so two reads could otherwise first-touch it together.
  ///
  /// A track whose length does not resolve is not cached at all. Readium
  /// memoizes that failure per instance and then fails every ranged read, so
  /// keeping it would cost the chapter; the caller reads unbuffered instead
  /// and the next request builds afresh.
  struct TrackEntry {
    /// nil over a local file, where a per-track window costs a read and a
    /// decrypt of its whole size to serve one segment and saves nothing.
    /// `readSource` then falls back to the unbuffered resource, which is what
    /// Readium serves a file-backed archive with anyway.
    let buffer: BufferingResource?

    /// Not optional: an entry exists only once the length is known. Readium's
    /// CBC resource turns a missing underlying length into a failure rather
    /// than a successful nil (`LCPDecryptor`: `requiredEstimatedLength`), and a
    /// buffer built without a length has a dead read-ahead clamp for its whole
    /// life, so "cached but unknown" is a state worth not having.
    let length: UInt64
  }

  /// `.some(entry)` once built, `.some(nil)` if it could not be, or `nil` if
  /// the CALLING request was cancelled first, so a cancelled request is never
  /// mistaken for a failed one and finished on its behalf.
  func trackEntry(for publication: Publication, href: String) async -> TrackEntry?? {
    // The ask the provider reads as "this chapter is waiting", and the answer
    // that saves the probe. Only asked when there is no entry for the track
    // yet: an entry carries its length, so a built track needs no wait.
    var supplied = provider?.cachedPlaintextLength(forHref: href)
    if supplied == nil, !bufferedTracks.withValue({ $0.contains { $0.href == href } }) {
      supplied = await provider?.plaintextLength(
        forHref: href, waitingUpTo: Self.lengthWaitTimeout
      )
    }
    let knownLengthWasAbsent = supplied == nil
    let build = bufferedTracks.withValue { cache -> Task<TrackEntry?, Never> in
      if let index = cache.firstIndex(where: { $0.href == href }) {
        let entry = cache.remove(at: index)
        cache.append(entry)
        return entry.task
      }
      let size = perTrackBufferSize
      // Read before the task so the task captures a Bool, not the provider.
      let bufferThisTrack = provider?.archiveIsLocalFile() != true
      // Likewise read before the task. A known length skips
      // `estimatedLength()` entirely, and that call is the expensive one: it
      // reads the entry's CBC tail, which sits a whole chapter away from the
      // audio, and was measured costing 17.8-28.8 MB of origin traffic to
      // serve no audio at all.
      let knownLength = supplied
      let task = Task<TrackEntry?, Never> {
        guard let resolved = Self.resource(for: publication, href: href, knownLength: knownLength) else {
          return nil
        }
        let length: UInt64
        if let knownLength {
          length = knownLength
        } else {
          guard case let .success(.some(probed)) = await resolved.estimatedLength() else {
            return nil
          }
          length = probed
        }
        return TrackEntry(
          buffer: bufferThisTrack ? resolved.buffered(size: size) : nil,
          length: length
        )
      }
      cache.append((href: href, task: task))
      // A `while` rather than one `removeFirst(count - bound)` call: the
      // subtracting form removes nothing when the count equals the bound, so
      // widening the comparison by one leaves behaviour identical and no test
      // can tell the bound apart from the bound plus one.
      while cache.count > maxBufferedTracks {
        cache.removeFirst()
      }
      return task
    }

    // Cancellation-aware, so a request AVFoundation has dropped stops waiting
    // on work it no longer wants instead of holding its slot (PP-5240).
    guard let built = await Self.value(of: build) else {
      return nil // this caller was cancelled; the build stands for the next one
    }
    if let built, knownLengthWasAbsent {
      // Outside the task deliberately: the provider is not `Sendable`, and the
      // existing comments above keep it out of the task for that reason.
      provider?.cachePlaintextLength(built.length, forHref: href)
    }
    if built == nil {
      bufferedTracks.withValue { cache in
        // Keyed on the task: it identifies this build uniquely, so an href
        // test would be redundant — and a redundant conjunct is a mutation no
        // test can distinguish.
        cache.removeAll { $0.task == build }
      }
    }
    return .some(built)
  }

  /// `resource(for:href:)`, given its plaintext length when that is known.
  ///
  /// Readium's CBC resource otherwise learns the length by fetching the entry's
  /// last blocks before it decrypts any range. On a streamed package that is a
  /// read a chapter away from the audio, measured at 18.6 MB to serve two bytes,
  /// and it cannot be cancelled once started (PP-5398).
  static func resource(for publication: Publication, href: String, knownLength: UInt64?) -> Resource? {
    let resolved = resource(for: publication, href: href)
    guard let knownLength, let lengthAccepting = resolved as? KnownLengthAcceptingResource else {
      return resolved
    }
    return lengthAccepting.withKnownLength(knownLength)
  }

  static func resource(for publication: Publication, href: String) -> Resource? {
    if let res = publication.get(Link(href: href)), type(of: res) != FailureResource.self {
      return res
    }
    if let res = publication.get(Link(href: "/" + href)), type(of: res) != FailureResource.self {
      return res
    }
    if let base = publication.linkWithRel(.self)?.href,
       let absolute = URL(string: href, relativeTo: URL(string: base)!)?.absoluteString
    {
      if let res = publication.get(Link(href: absolute)), type(of: res) != FailureResource.self {
        return res
      }
    }
    return nil
  }

  static func utiIdentifier(forHref href: String, fallbackMime: String?) -> String {
    let ext = URL(fileURLWithPath: href).pathExtension.lowercased()

    if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
      return type.identifier
    }

    switch ext {
    case "mp3":
      return "public.mp3"
    case "m4a":
      return "com.apple.m4a-audio"
    case "mp4":
      return "public.mpeg-4"
    default:
      break
    }

    if let mime = fallbackMime?.lowercased() {
      if mime.contains("mpeg") || mime.contains("mp3") {
        return "public.mp3"
      }
      if mime.contains("m4a") || mime.contains("mp4") {
        return "com.apple.m4a-audio"
      }
    }

    return "public.audio"
  }
}

// MARK: - Range clamp (PP-4542)

// Internal (not `private`) so the clamp logic is unit-testable via
// `@testable import` without standing up a real AVAsset + Readium Resource stack.
extension LCPResourceLoaderDelegate {
  /// Classifies a `Resource.read(range:)` error as a *range-out-of-bounds*
  /// failure. Readium 3.9.0 (PP-4340) / ReadiumZIPFoundation throws
  /// `Archive.ArchiveError.rangeOutOfBounds` when a requested range's upperBound
  /// exceeds the ZIP entry's `uncompressedSize` — i.e. the LCP resource reported
  /// a length larger than it can actually serve, so AVPlayer's tail probe
  /// overshoots. Matched on the error *description* so we don't couple to
  /// Readium's nested error-enum layout (which the 3.9.0 bump itself changed).
  static func isRangeOutOfBoundsError(_ error: Error) -> Bool {
    let desc = String(describing: error).lowercased()
    return desc.contains("rangeoutofbounds")
      || desc.contains("out of bounds")
      || desc.contains("out-of-bounds")
  }

  /// Reads `[start, requestedEnd)`, tolerating a length/size mismatch instead of
  /// failing. If the underlying resource throws `rangeOutOfBounds` (it reported a
  /// length larger than it can serve), this CLAMPS to the largest readable prefix
  /// via binary search and returns that, signalling EOF — rather than dead-ending
  /// the AVPlayerItem. This is the durable fix for the 3.2.0 first-open
  /// "Audiobook Unavailable" regression: AVPlayer's tail metadata probe overshoots
  /// the real decrypted size, and a hard failure there kills the whole item.
  ///
  /// Returns `(data, reachedEOF)`:
  ///   • a normal full read → `(data, data.count < requested)`,
  ///   • an overshoot clamped to the real end → `(clampedData, true)`,
  ///   • `start` already at/after EOF → `(empty, true)`.
  /// Non-bounds errors (decryption, cancellation, network) are re-thrown
  /// unchanged — never masked. Binary search only runs on the rare overshoot, so
  /// well-formed reads stay single-shot.
  ///
  /// `probe` is what the binary search and the final clamped read go through,
  /// and it must honour the upper bound it is given. A `BufferingResource` does
  /// not: it fetches `lowerBound ..< max(requested.upperBound, lowerBound +
  /// bufferSize)`, so for any read smaller than its buffer the caller's upper
  /// bound has no effect, every probe fetches the same over-long range and
  /// fails identically, and the search converges on `start` — returning empty
  /// with EOF, which `transfer` finishes SUCCESSFULLY. A chapter then reports
  /// fine and plays silence. So the fast path may be buffered; the search may
  /// not. It defaults to `read` for callers whose resource is already raw.
  /// For a caller whose resource is already unbuffered, where the read itself
  /// honours its upper bound and can serve as its own probe.
  static func readClampedToAvailable(
    start: UInt64,
    requestedEnd: UInt64,
    isOutOfBounds: (Error) -> Bool = LCPResourceLoaderDelegate.isRangeOutOfBoundsError,
    _ read: (Range<UInt64>) async throws -> Data
  ) async throws -> (data: Data, reachedEOF: Bool) {
    try await readClampedToAvailable(
      start: start,
      requestedEnd: requestedEnd,
      isOutOfBounds: isOutOfBounds,
      probe: read,
      read
    )
  }

  static func readClampedToAvailable(
    start: UInt64,
    requestedEnd: UInt64,
    isOutOfBounds: (Error) -> Bool = LCPResourceLoaderDelegate.isRangeOutOfBoundsError,
    probe: (Range<UInt64>) async throws -> Data,
    _ read: (Range<UInt64>) async throws -> Data
  ) async throws -> (data: Data, reachedEOF: Bool) {
    guard requestedEnd > start else { return (Data(), true) }
    do {
      let data = try await read(start..<requestedEnd)
      return (data, data.count < Int(requestedEnd - start))
    } catch {
      guard isOutOfBounds(error) else { throw error }
      func search(_ range: Range<UInt64>) async throws -> Data {
        try await probe(range)
      }
      // The real readable end is somewhere in [start, requestedEnd). Binary-search
      // the largest `end` for which read(start..<end) succeeds. Invariant:
      // read(start..<lo) is known-OK (lo==start ⇒ empty), read(start..<hi) failed.
      var lo = start
      var hi = requestedEnd
      while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2
        do {
          _ = try await search(start..<mid)
          lo = mid
        } catch {
          guard isOutOfBounds(error) else { throw error }
          hi = mid
        }
      }
      guard lo > start else {
        ATLog(.debug, "🎵 ResourceLoader: range start \(start) is past EOF — serving empty (clamped)")
        return (Data(), true)
      }
      let data = try await search(start..<lo)
      ATLog(.warn, "🎵 ResourceLoader: clamped overshooting range \(start)..<\(requestedEnd) to real EOF \(lo) (\(data.count) bytes) — LCP/ZIP length mismatch (PP-4542)")
      return (data, true)
    }
  }
}

// MARK: - Serving primitives

/// A failure the loader itself decides on, as opposed to one passed through
/// from Readium or the transport.
///
/// AVFoundation rebuilds a loader error from its code alone and drops the
/// domain: `-1001` comes back as `NSURLErrorDomain -1001 "The request timed
/// out"`, indistinguishable from a real network timeout. The stall bound used
/// that code until PP-5240, which is why the field reports could not tell the
/// loader's timer from the network. Codes here stay clear of the
/// `NSURLError` range (all negative) so they cannot be read as one.
enum LCPResourceLoaderError: Int, CustomNSError {
  /// A data transfer delivered no bytes for the loader's stall timeout.
  case transferStalled = 5240

  static var errorDomain: String { "LCPResourceLoader" }
  var errorCode: Int { rawValue }
  var errorUserInfo: [String: Any] {
    switch self {
    case .transferStalled:
      return [NSLocalizedDescriptionKey: "Streaming transfer delivered no data within the stall timeout"]
    }
  }
}

/// One admission slot on the loader's concurrency semaphore, released at most once.
final class RequestSlot: @unchecked Sendable {
  private let semaphore: DispatchSemaphore
  private let held = LockIsolated(false)

  init(_ semaphore: DispatchSemaphore) {
    self.semaphore = semaphore
  }

  func acquire() {
    semaphore.wait()
    held.value = true
  }

  func release() {
    let wasHeld = held.withValue { held -> Bool in
      defer { held = false }
      return held
    }
    if wasHeld {
      semaphore.signal()
    }
  }
}

/// Answers a loading request at most once. The transfer and its stall timer
/// race to finish the same request; only the first answer reaches AVFoundation.
final class FinishOnce: @unchecked Sendable {
  private let request: LCPStreamingLoadingRequest
  private let finished = LockIsolated(false)
  private let failureDescription = LockIsolated<String?>(nil)

  /// Why this request was failed, or nil if it was not. Read from the report
  /// `defer` in `serve`, which runs after every exit including the failing ones.
  var failure: String? { failureDescription.value }

  init(_ request: LCPStreamingLoadingRequest) {
    self.request = request
  }

  func respond(with data: Data) {
    guard !finished.value else { return }
    request.respond(with: data)
  }

  func succeed() {
    if claim() { request.finishLoading() }
  }

  func fail(_ error: Error) {
    if claim() {
      failureDescription.value = (error as NSError).localizedDescription
      request.finishLoading(with: error)
    }
  }

  private func claim() -> Bool {
    finished.withValue { finished -> Bool in
      defer { finished = true }
      return !finished
    }
  }
}

/// Resumes a continuation exactly once, whether the value or the cancellation
/// arrives first, and whether either arrives before the continuation exists.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
  private enum State {
    case idle
    case waiting(CheckedContinuation<T, Never>)
    case early(T)
    case done
  }

  private let lock = NSLock()
  private var state = State.idle

  func install(_ continuation: CheckedContinuation<T, Never>) {
    let early: T? = lock.withLock {
      switch state {
      case let .early(value):
        state = .done
        return value
      case .idle:
        state = .waiting(continuation)
        return nil
      case .waiting, .done:
        return nil
      }
    }
    if let early {
      continuation.resume(returning: early)
    }
  }

  func resume(with value: T) {
    let waiting: CheckedContinuation<T, Never>? = lock.withLock {
      switch state {
      case .idle:
        state = .early(value)
        return nil
      case let .waiting(continuation):
        state = .done
        return continuation
      case .early, .done:
        return nil
      }
    }
    waiting?.resume(returning: value)
  }
}

