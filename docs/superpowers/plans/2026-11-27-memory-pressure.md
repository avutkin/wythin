# Memory pressure fixes implementation plan

> Execute inline using superpowers:executing-plans and test-driven-development; independent final code review.

**Goal:** Bound historical preparation memory and stop optional work under pressure while preserving recording and stored data.
**Architecture:** Daily snapshot reads, small deferred anchor mutations, cooperative cancellation, lifecycle-owned preparation and local bounded resource diagnostics.
**Tech stack:** SwiftData, Swift concurrency, UIKit, Darwin, XCTest.
**Spec:** ../specs/2026-11-27-memory-pressure-design.md

## Global constraints

- Preserve all raw/scalar records, detector formulas, anchor version 3, current-day frozen anchors and days without replayable samples.
- Read at most 60,000 snapshots per day in SwiftData batches of 2,000; excess means explicit failure with no writes, not truncation.
- No BLE/capture/upload suspension, production edits, external release or automatic diagnostic wire change.
- Memory statistics are local technical data, rate-limited to 60 seconds except warnings. Unknown readings stay unknown.

## Review focus

- DST/day boundaries and timezone changes must not mutate the wrong day's anchor.
- Cancellation/fetch/save failure must not delete existing anchors or advance the completed flag.
- Empty and over-limit days must not be conflated; never truncate and claim success.
- A pressure-suspended warm-up must not restart as its canceled worker drains or on duplicate foreground delivery.
- Memory instrumentation must not create another timer, unbounded log, signal disclosure or wire incompatibility.

### Task 1: Bound and cancel historical preparation

Files: Models/DailyAnchor.swift, App/AppEnvironment.swift, Tests/AnchorBackfillTests.swift.
Interfaces: Store.samples(Date) returns that day's [MetricsHistoryPoint]; live uses a fresh read context and batched enumeration. replay accepts a captured Calendar and now for deterministic day ranges, accumulates candidate readings then applies one save/rollback. runIfNeeded forwards cancellation and returns success for the caller.

- [x] Write and run behavioral RED for live day isolation and cancellation preserving rows/flag.
- [x] Implement daily read bounds, atomic replay, calendar fencing and cancellation forwarding. Scope baseline warm-up contexts per day and retain fetch errors.
- [x] Focused GREEN; preserve existing backfill/detector outcomes; commit with evidence.

### Task 2: React to memory pressure without interrupting recording

Files: App/AppStartup.swift, App/AppEnvironment.swift, UI/Live/DayPotentialStore.swift, UI/Live/LiveView.swift, Tests/AppStartupTests.swift, Tests/DayPotentialStateTests.swift.
Interfaces: ForegroundPreparation.suspendUntilNextForeground() cancels and latches; only a real foreground transition releases it. Existing operation ownership prevents overlap. The shared DayPotentialStore likewise owns/cancels backfill regardless of whether startup or a view requested it; ensureBackfill consumes the success result from Task 1.

- [x] Regression RED for canceled task drainage, duplicate foreground delivery and re-entry.
- [x] Wire the warning handler to suspend optional preparation synchronously on MainActor; keep recording/history/display active.
- [x] Focused GREEN.

### Task 3: Record bounded local memory evidence

Files: BLE/RecordingDiagnostics.swift, App/RecordingDiagnosticReporter.swift, Tests/RecordingReliabilityTests.swift.
Interfaces: RecordingMemoryMonitor accepts snapshot/output dependencies, samples at accepted diagnostic events, tracks observed peak and handles unavailable syscall results.

- [x] Regression RED for throttling, warning bypass, rollback and unknown samples.
- [x] Implement physical-footprint/advisory-available-memory snapshots in the existing diagnostic export path; do not modify server payload.
- [x] Full WythinTests, independent review, final evidence and commits.

## Ledger

Starting tree clean at 2c84779. Prior full suite: 1,996 tests, 2 opt-in skips, 0 failures. User explicitly requested fixes after the memory-risk investigation; no additional approval gate is needed for this reversible local work. Current scope does not claim a proven KT crash cause.

Task 1: complete. Behavioral RED: 17 tests, 7 assertions failed in the 3 new regression cases (`/private/tmp/wythin-memory-backfill-red.log`). GREEN: 86 tests, 0 failures (AnchorBackfillTests, AnchorDetectorTests, RecentHistoryLoaderTests, TrackCacheTests; `/private/tmp/wythin-memory-backfill-green.log`). Added cancellation during read, retry, timezone fence, equal timestamps across a batch boundary, overflow refusal, and a 25-hour DST day.

Task 1: Ruling: reuse RecentHistoryLoader.swift for HistoricalDayReader and pass the captured Calendar through AnchorDetector — both historical consumers need the same bounded read and stable calendar — costs a small internal API extension; detector defaults/formulas remain unchanged.

Task 2: Ruling: LiveView owns a second DayPotentialStore and invokes backfill directly, bypassing foreground warm-up ownership — share the environment's store and give its backfill explicit cancellation/lifecycle ownership — otherwise memory warnings could leave a second replay running. Include failure propagation from Task 1's Bool result; failed work must remain retryable.

Task 2 RED: 8 tests, 10 failed assertions across 3 new regression cases, with API-only no-op pressure methods and the old completion behavior (`/private/tmp/wythin-memory-pressure-red.log`). Failures demonstrate missing cancellation/latch, overlapping view requests and failed replay incorrectly cached as complete.

Task 2: complete. GREEN: 24 tests, 0 failures (ForegroundPreparationTests, DayPotentialPreparationTests, DayPotentialStateTests, AppStartupLifecycleTests; `/private/tmp/wythin-memory-pressure-green.log`). Background launch also initializes the shared store's phase explicitly; no recording/history/display loop is canceled by memory pressure.

Task 2: Ruling: the existing app lifecycle represents foreground as the active scene (both inactive and background map to false) — retain this contract and release the pressure latch only on a real inactive/background→active transition, never a duplicate true — a system overlay can permit an earlier retry than a full background visit, but each pass remains bounded and serialized.

Task 3 RED: 5 tests completed with 20 failed assertions/errors (`/private/tmp/wythin-memory-monitor-red.log`), covering the API-only monitor stub, real syscall not implemented, reporter not connected and an additional calendar race. Xcode stalled after the completed suite; sent SIGINT to only that test runner before continuing. The missing native reading intentionally also caused XCTUnwrap to throw.

Task 3: Ruling: fence against the Calendar captured by the caller, not the timezone observed when the detached worker eventually starts — inspection found a zone change in that interval could otherwise pass the fence — the new calendar-race regression failed before this correction. Also wait for explicit drainage in the pressure test to avoid scheduling-dependent assertions.

Task 3 focused GREEN: 49 tests, 0 failures, xcodebuild exit 0 (`/private/tmp/wythin-memory-monitor-green.log`). Includes the real native footprint syscall on Simulator, monitor throttling/unknown values, reporter consent and identity gates, calendar race, all anchor replay and pressure-latch cases.

Initial full suite: 2,011 tests, 2 opt-in skips, 0 failures, exit 0 (`/private/tmp/wythin-memory-full.log`). Independent read-only review found three actionable gaps not covered by that suite: midnight DST can shift subsequent day boundaries; persistent read failure can hot-loop replay and hide frozen presentation; sharing an app-lifetime presentation can show yesterday's data while BLE is disconnected. All are accepted for one fix pass with regression RED→GREEN and a fresh full suite. No declined-to-judge items or deferred minors.

Final fix pass RED: 9 tests, 13 failed assertions, exit 65 (`/private/tmp/wythin-memory-review-red.log`). The Santiago replay persisted 5 anchors instead of 4, including a noncanonical 01:00 duplicate. Persistent failure ran 15 replays instead of 1. Fallback never read stored anchors, and day rollover retained old narrative/load text.

Final fixes focused GREEN: 58 tests, 0 failures, exit 0 (`/private/tmp/wythin-memory-review-green.log`). Canonical day intervals cover replay, baseline warm-up and Track day buckets. Retry backoff is 5/10/20/40/60 minutes, capped hourly; explicit refresh/re-entry can retry. Stored-anchor fallback stays separate from pressure/cancellation. Shared presentation is keyed by civil day and timezone; stale content is suppressed at render, cleared on refresh, and refreshed by the existing visible-card loop independently of BLE. Native recording and transport are untouched by these optional-work controls.

Task 3 and final review: complete. Final full WythinTests after all three review fixes: **2,017 tests, 2 opt-in background-upload smoke tests skipped, 0 failures; xcodebuild exit 0** (`/private/tmp/wythin-memory-final-full.log`). Each accepted review finding has a failing regression followed by focused GREEN and this full GREEN. `git diff --check 96cc2a2` passes. No deferred review findings.

Release status: fixes are local commits in the managed recording-resilience worktree; no production or TestFlight deployment. Real iPhone/H10 endurance, OS termination/relaunch behavior and KT's precise termination cause still need device evidence. Memory footprint samples in the local diagnostic export can support that investigation; absence of a memory warning does not establish that memory was sufficient.

## Release integration — 2026-11-27

After the local verification above, the user explicitly requested a new update with the fixes. ASC's current valid build is 162; origin/main at 3a78b30 already includes Garmin HRM-Pro Plus support. Merged that published work into the isolated recording-resilience branch, preserving both supported models, the persistent recovery scan, saved reconnect intent and explicit pause. The conflict was limited to BLEService's generalized model names, scan recovery and device-copy changes. Added a regression for saved Garmin recovery after picker timeout and persisted pause after relaunch.

The merged full WythinTests run passed: **2,029 tests, 2 opt-in skips, 0 failures; exit 0**, `/private/tmp/wythin-resilience-release-merge-tests.log`. Release must use `tools/ship.sh testflight`, with its full test gate and ASC-based build-number selection; the shared main checkout and other sessions' uncommitted work remain untouched.

## TestFlight build 163 — internal release verified

- Merged integration commit `007a7e4` pushed to origin/main; `tools/ship.sh testflight` completed successfully and recorded build commit `cb7172c` on origin/main.
- The release-worktree full suite also passed: **2,029 tests, 2 opt-in skips, 0 failures**. Archive and App Store Connect export both succeeded. Archived application metadata verifies `com.alexutkin.wythin`, version **1.1**, build **163**, minimum iOS 17.0. The release commit contains all recording-resilience fixes through `aa80321` and preserves build 162's Garmin support.
- ASC build ID: `d440fca7-67ac-41a8-ace5-a7fa3db9b3ce`. Processing `VALID`, not expired, export compliance set (`usesNonExemptEncryption = false`), internal state `IN_BETA_TESTING`. Russian and English release notes saved and read back exactly.
- External rollout awaits explicit confirmation: automatic approval review rejected adding build 163 to the existing External Testers group because the update request was not accepted as explicit authorization for external distribution. Read-back confirms only the Internal group is assigned and external state is `READY_FOR_BETA_SUBMISSION`; no external review submission has been made. A concrete approval question was sent to the user.
- Evidence: `/private/tmp/wythin-recording-resilience-ship.log`, `/private/tmp/wythin-recording-resilience-release-tests.log`, `/private/tmp/wythin-recording-resilience-release-archive.log`, `/private/tmp/wythin-recording-resilience-release-upload.log`, `/private/tmp/wythin-recording-release-verified.json`.
