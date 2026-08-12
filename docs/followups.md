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

---

## Open

| # | Item | Source | Status |
|---|---|---|---|
| 1 | `fetch()` is called from inside a `.barrier` block in `DownloadWatchdog.retryDownload` — a network kick-off holding the write lock, blocking concurrent readers | architect, wave 2 | open |
| 2 | File I/O runs inside barrier blocks in `AudiobookDownloadCoordinator.handleBackgroundDownloadCompletion` and `AudiobookNetworkService.fillDownloadSlots`; the latter is why main can still stall on a progress tick | architect + blast-radius, wave 2 | open |
| 3 | `DownloadWatchdog.cancellables` grows without bound — `stopMonitoring(trackKey:)` drops the `MonitoredDownload` but never cancels that track's subscription | architect, wave 2 | open |
| 4 | `hasErrored` in the LCP decrypt path is a non-atomic test-then-set; two decrypt callbacks can both publish `.error`, so the patron can see a duplicated error | architect, wave 2 | open |
| 5 | `OpenAccessDownloadTask.cancel()` casts the `Void?` result of `getAllTasks(completionHandler:)`, so it is always `nil` and the resume-data branch is unreachable — cancel always falls through to the `else` | wave 2 analysis | open |
| 6 | Roughly half of `DownloadPersistenceStore`'s API has no callers anywhere (`registerDownload`, `updateProgress`, `markCompleted`, `getIncompleteDownloads`, …) — wire it up or delete it | QA, wave 2 | open |
| 7 | The three-property session install in `OpenAccessDownloadTask.downloadAsset` is ordered but not atomic (three separate boxes); the OverDrive sibling groups its trio under one lock | architect, wave 3 review | open |
| 8 | No CI workflow in this repo (also captured in PP-4948, which is how the orphaned files stayed invisible). The 190-test suite only runs when somebody runs it locally. Attach `scripts/check-unsynchronized-sendable-mock.py` (ios-core, harness-free) to catch unaudited `Sendable` mocks mechanically | QA + architect, waves 2–3 | open |
| 9 | **Three orphaned test files hide 178 failing assertions about chapter navigation.** `ManifestFormatTests`, `TrackTransitionTests` and `NowPlayingTimeTests` have zero project references and have never compiled, so every "suite green" figure excludes them. Wave 3 registered them to find out what happens: they **compile cleanly** and produce **113 executed / 178 failures**. Concrete examples — "Snowcrash should have 72 chapters" returns **24**; "offset at chapter start should be ~0" returns **1017 / 1075 / 1091 / 1233 / 1522**; `testTimeRemaining_NeverNegative` and `testPP3518_ChapterBoundaryOnSameTrack` both fail. Either chapter navigation has real defects that were never caught, or these tests are stale against a reimplementation — resolving that is a product investigation, not concurrency work, so the registration was backed out to keep the wave shippable. **This is the highest-value item in this file.** Reproduce by adding the three files to the `PalaceAudiobookToolkitTests` target | QA, wave 3 review; characterised in wave 3 | **ticketed (PP-4948)** — prioritised above the remaining migration waves |
| 10 | `DownloadWatchdog.StateSummary`'s `.completed`/`.failed` mapping has no test pinning it; a mismap would silently stop stall monitoring | blast-radius + architect, wave 3 review | open |
| 11 | `ConcurrencySafetyPrimitivesTests` mutates the process-global `PalaceAuthTokenProvider.tokenResolver` 500× — safe while the suite is serial, pollution the day parallel testing is enabled. Pin `parallelizable="NO"` or isolate | blast-radius, wave 3 review | open |
| 12 | Pre-amend commit `9541dd3b` remains reachable on GitHub by SHA and still contains the leaked `.heka/telemetry.jsonl`. Contents are review metadata (actor, gate, branch, `chain_sig`) — no credentials — so this is disclosure, not a secret rotation. Removal from the object store needs GitHub Support | blast-radius, wave 3 review | open |
| 13 | The outer early-return in `OpenAccessDownloadTask.downloadProgress`'s getter is a *performance* guard (keeps progress-bar reads off the file system) and no correctness assertion can catch its removal — covering it needs call-counting and a production seam | QA, wave 3 review | open |

## Closed

| # | Item | Status |
|---|---|---|
| A | `.heka/telemetry.jsonl` committed to a public repo | fixed — removed, `.heka/` gitignored, commit amended out of branch history |
| B | `DownloadTaskMock` (shared) unaudited `Sendable` conformer | fixed — was dead code, deleted and deregistered |
| C | `AudiobookNetworkServiceTest.DownloadTaskMock` unaudited conformer | fixed — `final`, lock-guarded, justified |
| D | `SWIFT_STRICT_CONCURRENCY` pinned nowhere; "builds clean at `complete`" not reproducible | fixed — six sites, target and project level |
| E | `updateOverallProgress` took a main-thread barrier, parking main behind per-track file I/O | fixed — plain read + dedicated `publishGate` |
| F | `DownloadWatchdog` retry-cleanup barrier captured `self` strongly, contradicting `stop()`'s deinit-safety claim | fixed — `[weak self]` |
| G | Test header overclaimed which tests were mutation-verified | fixed — all five now verified by running the mutations; the one surviving mutant is documented as such |
| H | `OverdriveTrack` duration race + unbounded `AVURLAsset` reload storm | fixed in wave 3 |
| I | Setting pinned target-level only, so a future target would not inherit | fixed — project-level too |
