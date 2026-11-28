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

- [ ] Regression RED for throttling, warning bypass, rollback and unknown samples.
- [ ] Implement physical-footprint/advisory-available-memory snapshots in the existing diagnostic export path; do not modify server payload.
- [ ] Full WythinTests, independent review, final evidence and commits.

## Ledger

Starting tree clean at 2c84779. Prior full suite: 1,996 tests, 2 opt-in skips, 0 failures. User explicitly requested fixes after the memory-risk investigation; no additional approval gate is needed for this reversible local work. Current scope does not claim a proven KT crash cause.

Task 1: complete. Behavioral RED: 17 tests, 7 assertions failed in the 3 new regression cases (`/private/tmp/wythin-memory-backfill-red.log`). GREEN: 86 tests, 0 failures (AnchorBackfillTests, AnchorDetectorTests, RecentHistoryLoaderTests, TrackCacheTests; `/private/tmp/wythin-memory-backfill-green.log`). Added cancellation during read, retry, timezone fence, equal timestamps across a batch boundary, overflow refusal, and a 25-hour DST day.

Task 1: Ruling: reuse RecentHistoryLoader.swift for HistoricalDayReader and pass the captured Calendar through AnchorDetector — both historical consumers need the same bounded read and stable calendar — costs a small internal API extension; detector defaults/formulas remain unchanged.

Task 2: Ruling: LiveView owns a second DayPotentialStore and invokes backfill directly, bypassing foreground warm-up ownership — share the environment's store and give its backfill explicit cancellation/lifecycle ownership — otherwise memory warnings could leave a second replay running. Include failure propagation from Task 1's Bool result; failed work must remain retryable.

Task 2 RED: 8 tests, 10 failed assertions across 3 new regression cases, with API-only no-op pressure methods and the old completion behavior (`/private/tmp/wythin-memory-pressure-red.log`). Failures demonstrate missing cancellation/latch, overlapping view requests and failed replay incorrectly cached as complete.

Task 2: complete. GREEN: 24 tests, 0 failures (ForegroundPreparationTests, DayPotentialPreparationTests, DayPotentialStateTests, AppStartupLifecycleTests; `/private/tmp/wythin-memory-pressure-green.log`). Background launch also initializes the shared store's phase explicitly; no recording/history/display loop is canceled by memory pressure.
