# Follow-up ledger

Every deferred item from a review or a migration wave lands here the moment it
is deferred. Nothing is "remembered" — if it is not written down here it does
not exist, and it will be dropped.

## Why this file exists

The Swift 6 migration (PP-4724) is landing in waves, and each wave's review
surfaces findings that are real but out of scope for that wave: pre-existing
hazards, behaviour changes too risky to bundle with a safety refactor, and
tooling gaps. Across waves 1 and 2 roughly fifteen such items accumulated in
commit-message stanzas and reviewer transcripts, which are not places anyone
looks later.

## The practice

1. **When a review defers something, add a row here in the same commit.**
   Not afterwards, not in a ticket you intend to file — here, now.
2. **Every wave opens by reconciling this file.** Close what the wave fixed,
   and pull in anything cheap enough to fold into the files that wave already
   touches. That is the point: a follow-up parked next to code you are about to
   edit anyway should be done, not deferred again.
3. **Every wave's commit says what it closed and what it did not.** The
   `**Not done:**` / `**Deferred:**` stanza and this file must agree.
4. **An item leaves this file in exactly two ways**: it is fixed (with the
   commit that fixed it), or it is promoted to a tracked ticket with the ticket
   ID recorded. "It seemed minor" is not one of them.

Status values: `open`, `fixed (<sha>)`, `ticketed (<id>)`, `wontfix (<reason>)`.

Two clarifications, both from review findings against this file:

- **A row closed by the same commit that closes it cannot cite its own sha.**
  In that case name the artefact instead — the test, the type, the function —
  which is stable and greppable. A sha is used when the fix landed earlier.
- **Closing a row renames it** (numbers in Open, letters in Closed), which
  breaks every prior reference to it. Carry the old identifier forward as
  `<letter> (was item <n>)` so a commit message or review that cites the number
  still resolves.

---

## Open

| # | Item | Raised by | Status |
|---|---|---|---|
| 1 | `fetch()` is called from inside a `.barrier` block in `DownloadWatchdog.retryDownload` — a network kick-off holding the write lock, blocking concurrent readers | review, wave 2 | open |
| 2 | File I/O runs inside barrier blocks in `AudiobookDownloadCoordinator.handleBackgroundDownloadCompletion` and `AudiobookNetworkService.fillDownloadSlots`; the latter is why main can still stall on a progress tick | review, wave 2 | open |
| 3 | `DownloadWatchdog.cancellables` grows without bound — `stopMonitoring(trackKey:)` drops the `MonitoredDownload` but never cancels that track's subscription | review, wave 2 | open |
| 4 | `hasErrored` in the LCP decrypt path is a non-atomic test-then-set; two decrypt callbacks can both publish `.error`, so the patron can see a duplicated error | review, wave 2 | open |
| 5 | `OpenAccessDownloadTask.cancel()` casts the `Void?` result of `getAllTasks(completionHandler:)`, so it is always `nil` and the resume-data branch is unreachable — cancel always falls through to the `else` | wave 2 analysis | open |
| 6 | Roughly half of `DownloadPersistenceStore`'s API has no callers anywhere (`registerDownload`, `updateProgress`, `markCompleted`, `getIncompleteDownloads`, …) — wire it up or delete it | review, wave 2 | open |
| 7 | The three-property session install in `OpenAccessDownloadTask.downloadAsset` is ordered but not atomic (three separate boxes); the OverDrive sibling groups its trio under one lock | review, wave 3 | open |
| 8 | No CI workflow in this repo (also captured in PP-4948, which is how the orphaned files stayed invisible). The 190-test suite only runs when somebody runs it locally. Attach `scripts/check-unsynchronized-sendable-mock.py` (ios-core, harness-free) to catch unaudited `Sendable` mocks mechanically | review, waves 2–3 | open |
| 9 | **Three orphaned test files hide 178 failing assertions about chapter navigation.** `ManifestFormatTests`, `TrackTransitionTests` and `NowPlayingTimeTests` have zero project references and have never compiled, so every "suite green" figure excludes them. Wave 3 registered them to find out what happens: they **compile cleanly** and produce **113 executed / 178 failures**. Concrete examples — "Snowcrash should have 72 chapters" returns **24**; "offset at chapter start should be ~0" returns **1017 / 1075 / 1091 / 1233 / 1522**; `testTimeRemaining_NeverNegative` and `testPP3518_ChapterBoundaryOnSameTrack` both fail. The registration was backed out to keep the wave shippable. **Triaged in wave 3 round 3, and the answer is BOTH — it is not simply stale tests.** The 178 assertions are 9 distinct tests: two are genuinely stale (they assert the pre-collapse chapter count, and `keepFirstChapterPerTrackKey` collapses a dense TOC to one chapter per physical file by design); one is a fixture gap (`animalFarm_manifest` has no title); two are mis-specified (they assert `chapterOffset` clamps to the *iterated* chapter's duration, when it clamps to the *resolved* chapter's); and **four describe a real defect.** `chapter(forPosition:)` scans in order and matches a position against a chapter's span OR its exact end, and because `calculateEndPosition` sets each chapter's end to exactly the next chapter's start, a position at a boundary matches the PREVIOUS chapter first — with a 0.5s tolerance, so the first half-second of every chapter is attributed to the chapter before it. `testPP3518_ChapterBoundaryOnSameTrack` reports `t=3.0` and `t=3.1` both returning `"Part I"` where `"Chapter 2"` is expected; it is a named regression test for a shipped ticketed fix, so this is a regression against intended behaviour, not drift | review, wave 3; triaged in wave 3 round 3 | **ticketed (PP-4948)** |
| 10 | `DownloadWatchdog.StateSummary`'s `.completed`/`.failed` mapping has no test pinning it; a mismap would silently stop stall monitoring | review, wave 3 | open |
| 12 | A local review-tooling artefact was committed and pushed in wave 2, then removed and gitignored. The pre-amend commit remains reachable by SHA. Contents were review metadata, no credentials — disclosure, not a secret rotation. Full detail is held outside this repo | wave 3 review | open |
| 13 | The outer early-return in `OpenAccessDownloadTask.downloadProgress`'s getter is a *performance* guard (keeps progress-bar reads off the file system) and no correctness assertion can catch its removal — covering it needs call-counting and a production seam | review, wave 3 | open |
| 14 | `LCPTrack.setStreamingResource(_:)` has zero callers and `streamingResource` zero readers, in the toolkit and in ios-core — dead public API carried through the migration rather than removed | review, wave 3 | open |
| 15 | **The epic's headline metric may be measured in the wrong language mode.** Both targets are `SWIFT_VERSION = 4.2`, where `SWIFT_STRICT_CONCURRENCY = complete` *emits* diagnostics but cannot *enforce* them — a non-final class conforming to `Sendable` is a hard error in Swift 5/6 and only a warning here. So "the compiler enforces it" is false today, and 385→280 is not the number Swift 6 mode will judge. Discharge is measure-and-record: one build at `-swift-version 5`, before later waves optimise against a number that may not survive the flip | review, wave 3 | open |
| 21 | **`preferChapterEndingHere` is live debt across six call sites, and the picture around it was restated four times before it was right — trust this row, not the commit bodies.** PP-4948 corrected which chapter a boundary position belongs to, but the six sites feeding `.completed(chapter)` are pinned to the OLD tie-break. **Per path:** on open-access/LCP `.completed` never fires mid-book; on **Findaway it fires every chapter and always has** (`FAEPlaybackChapterComplete`; `FAEPlaybackAudiobookComplete` is the separate end-of-book event), so the flip changes only WHICH chapter is named there, not whether it fires. **Measured:** the old tie-break names the chapter BEFORE the one that finished, 9 of 10 chapters on `secret_lives_manifest`. **What the flip does NOT do:** `handlePlaybackCompleted` saves `chapter.position` — the chapter START — so it moves the save from "start of N−1" to "start of N", still behind the real position. **What is UNMEASURED and decides the real severity:** `AudiobookPlaybackModel` separately throttles `.positionUpdated` at 5s, filters on `>2.0s` drift, and saves the LIVE position — so a chapter-start save is probably overwritten within seconds while that model is alive and saves are not suppressed. Nobody has measured whether it wins the race. **And a FOREGROUND-ONLY measurement will return a falsely benign answer, so it must not close PP-4951:** the mitigation's carrier is `.positionUpdated`, which has exactly two producers (`AudiobookManager` `:396` one-shot and `:595` `setupNowPlayingInfoTimer`), and this repo already documents from field data (~23k events through 3.2.3, the NowPlaying-403 dry stream) that iOS coalesces and suspends that main-runloop timer during long screen-locked background playback — it goes dry >30s while audio keeps playing, its background interval is 15s even when it does fire, and the `positionPublisher` heartbeat deliberately does NOT re-publish `.positionUpdated`. `FAEPlaybackChapterComplete` is SDK-driven and keeps firing throughout. So in exactly the scenario where a patron is most likely to stop listening, the wrong save fires and the thing that would overwrite it does not. **On pausing:** the app's `.playbackCompleted` arm sets `.paused` for every path, so Findaway already does this per chapter; nothing calls `player.pause()`, so audio continues, and the toolkit's own model re-syncs from a 0.5s `isPlaying` poll. The app-level session manager has no such poll, and `FAEPlaybackChapterComplete` is documented in-repo as arriving seconds late, so a stuck `.paused` with a stale position is a plausible but UNREPRODUCED hazard. If this parameter outlives the ticket, make it a two-case enum | review, PP-4948 | **ticketed (PP-4951)** |
| 19 | `.completed` is not rate-limited, and every one of them re-arms `OverdriveTrack`'s duration budget. Reachability flapping drives `fetch()` repeatedly, so a present-but-unreadable file can be re-read up to the attempt bound per completion, without limit on completions. Bounded per event and no worse than `origin/main` (which retried on every read), so not a regression — but the work is bounded only by how often the app is told the network came back | review, wave 3 round 5 | open |
| 20 | `settle(0.5)` in `OverdriveTrackDurationTests` is a wall-clock pause. Since round 4 it can flake RED rather than fail open, which is the safer direction, and a reviewer measured 64 executions with 0 failures at load 11 — but it is still a timing assumption in a test that exists because timing was the defect. Replacing it needs a completion signal from the production `Task`, i.e. a seam | review, wave 3 round 5 | open |
| 22 | `AudiobookTableOfContents` is now trivially `Sendable`-able and was left out of wave 3 part 2 on scope grounds. Its three stored properties — `Manifest`, `Tracks`, `[Chapter]` — all became `Sendable` in that wave, so the conformance is a one-line change plus an audit of its `mutating` members. Until it lands, every `AudiobookTableOfContents` crossing an isolation boundary is still a diagnostic, and it is carried by `AudiobookManager`, both players and the app's bookmark layer | wave 3 part 2 | open |
| 23 | `Tracks.token` does not propagate to the already-built tracks or their download tasks, while `Tracks.fulfillURL` does. Wave 3 part 2 preserved that asymmetry deliberately rather than change behaviour inside a safety refactor, and documented it on the property. It may be harmless — `OpenAccessDownloadTask` has its own refresh path that writes its own `token` — but nobody has traced whether a token refreshed by `OpenAccessPlayer` needs to reach a download in flight. Decide, then either propagate or write the reason down as a test | wave 3 part 2 | open |
| 24 | Wave 3 part 2's `-swift-version 5` probe (partial discharge of item 15) found the framework target has exactly **two** compile errors under Swift 5, and **neither is a concurrency diagnostic**: `LCPResourceLoaderDelegate.swift:234` and `:252` bind `try? await res.estimatedLength().get()` as a double optional, which Swift 5 rejects (`initializer for conditional binding must have Optional type, not 'UInt64'`), and one `cannot use optional chaining on non-optional value of type '[String : Any]'`. `cannot conform to 'Sendable'` was **0**. These two must be fixed before item 15 can produce a clean whole-module Swift 5 warning count | wave 3 part 2 | open |
| 25 | The test scheme runs with no ThreadSanitizer, so a genuine data race — the `Tracks.token` plain `var` this wave replaced, for instance — cannot fail the suite. Every concurrency guard here is therefore pinned by an *observable* consequence (`fulfillURL` disagreeing with the tasks) rather than by race detection. Enabling TSan on a dedicated scheme, or on the CI job item 8 asks for, would make the next wave's claims checkable rather than argued | wave 3 part 2 | open |
| 18 | `fileExists` is not "the file is complete". `MediaProcessor.optimizeQTFile`, which the shared download delegate reaches through `verifyDownloadAndMove`, creates a **zero-byte file at the final url** and then writes it progressively, so every existence check passes throughout the write. `OverdriveTrack` now tolerates this defensively, but note the optimising branch is NOT reachable from the Overdrive path today — `fetch()` only downloads `.audioMP3` and `fileNeedsOptimization` needs both `mdat` and `moov` atoms, so that path takes the atomic `moveItem`. It IS reachable on the OpenAccess path, which handles MP4/M4B, and nothing there has been audited. Related and worse: `.completed` itself is sent on a bare `fileExists` (`assetFileStatus() == .saved`), and `AudiobookPlaybackModel` calls `fetch()` on every player open, so a truncated file produces a completion signal on each open | review, wave 3 rounds 3–4 | open |

## Closed

| # | Item | Status |
|---|---|---|
| A | A local review-tooling artefact was committed to a public repo | fixed — removed, gitignored, commit amended out of branch history. Same disclosure as open item 12 |
| B | `DownloadTaskMock` (shared) unaudited `Sendable` conformer | fixed — was dead code, deleted and deregistered |
| C | `AudiobookNetworkServiceTest.DownloadTaskMock` unaudited conformer | fixed — `final`, lock-guarded, justified |
| D | `SWIFT_STRICT_CONCURRENCY` pinned nowhere; "builds clean at `complete`" not reproducible | fixed — six sites, target and project level |
| E | `updateOverallProgress` took a main-thread barrier, parking main behind per-track file I/O | fixed — plain read + dedicated `publishGate` |
| F | `DownloadWatchdog` retry-cleanup barrier captured `self` strongly, contradicting `stop()`'s deinit-safety claim | fixed — `[weak self]` |
| G | Test header overclaimed which tests were mutation-verified | fixed — all five now verified by running the mutations; the one surviving mutant is documented as such |
| H | ~~`OverdriveTrack` duration race + unbounded reload storm — "fixed in wave 3"~~ **REOPENED, then closed as item 16.** The race was fixed; the storm was not. The premature closure is struck through rather than deleted, because a closed row that was never true is worse than an open one | see item 16 |
| I | Setting pinned target-level only, so a future target would not inherit | fixed — project-level too |
| J (was item 11) | `ConcurrencySafetyPrimitivesTests` mutates a process-global resolver 500×, unsafe once parallel testing is on | fixed in wave 3 — scheme pinned `parallelizable="NO"` |
| M | The `supersededByCompletion` transition added in round 3 discarded the completion's re-arm when the superseded attempt itself FAILED. A completion arriving during the last permitted attempt was consumed as the flag, the budget reached its limit, and every later claim was refused — a fully-downloaded track reporting duration 0 for the session. Found by review, proven with a probe, not by the tests written alongside the transition | fixed in wave 3 round 5 — the completion wins over the failure; `testCompletionDuringTheFinalAttempt_DoesNotStrandTheTrack` |
| L | The wave-3 public API break was disclosed only in the pull-request body, which nobody reads after the merge | fixed in wave 3 round 3 — "Breaking changes" section in `README.md`, beside the integration instructions |
| K (was item 16) | `OverdriveTrack`'s duration machine was unpinned by any test, and two further defects were found by reading it: the `.failed(attempts:)` bound never counted (the claim discarded the count, so `attempts` was pinned at 1 and the retry was unbounded), and `allowOneMoreResolution()` had zero callers while the download-completion sink clobbered a load already in flight | fixed in wave 3 round 3 — `TrackDurationLoader` seam injected; seven tests in `OverdriveTrackDurationTests` |
