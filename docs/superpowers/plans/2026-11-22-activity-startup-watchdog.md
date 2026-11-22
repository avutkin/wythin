# Activity startup watchdog implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the symbolicated activity-backfill startup watchdog on builds 159/160.
**Architecture:** One environment-owned coordinator runs version migration and ongoing window repair sequentially on a detached worker. Settled windows remain settled when their stress value is legitimately absent.
**Tech Stack:** Swift, SwiftData, SwiftUI, XCTest.
**Spec:** docs/superpowers/specs/2026-11-22-activity-startup-watchdog-design.md

## Global constraints
- Preserve all stores, schemas, calculation formulas and version 11; no reset or forced migration.
- No heavy fetch/computation from launch or scene-phase main actor callbacks.
- One pending follow-up, own background ModelContext, six-entry progress saves.
- Use tools/ship.sh for TestFlight/device installation; existing release authorization applies.

## Review focus
- A settled imported workout with no Polar samples must not become perpetual launch work.
- Simultaneous content/foreground requests must not run migrations concurrently.
- A store failure must remain retryable without advancing uncommitted progress.
- Active activities and after-windows still filling must retain their existing semantics.
- Background persistence must not erase local activity edits or expose an empty replacement store.

### Task 1: Move activity maintenance out of startup UI work

**Files:** Create App/ActivityWindowMaintenance.swift and WythinTests/ActivityWindowMaintenanceTests.swift; modify Models/ActivityLog.swift, App/AppEnvironment.swift, App/WythinApp.swift and project.pbxproj.
**Consumes:** ModelContainer; ActivityLog.migrate(context:); ActivityLog.backfillMissingWindows(context:).
**Produces:** @MainActor ActivityWindowMaintenance(container:work:) with request() returning a shared Task<Void,Never>; AppEnvironment.refreshActivityWindows() schedules its owned coordinator.

- [ ] Write regression tests: a settled activity with nil duringStress does not need refresh; a slow maintenance job executes off the main thread and allows a main-actor heartbeat; repeated requests coalesce; a failed worker allows a later retry; real history is preserved and missing windows become durably settled.
- [ ] Run the focused tests and observe the old predicate and synchronous execution fail.
- [ ] Correct the predicate order; implement the detached/coalesced coordinator; route both ContentView and scene activation through it; save ongoing repair every six entries with no progress advance on save failure.
- [ ] Run focused activity tests and full WythinTests suite on simulator 13E49A03-B74A-4D83-80DF-994C88500356, absolute project path, normal signing. Require TEST SUCCEEDED and zero failures.
- [ ] Commit; obtain one independent whole-change review; address Important/Critical findings in one test-driven pass.
- [ ] Integrate main, ship TestFlight, verify external availability, and validate startup on the reachable physical iPhone through ship.sh phone if available. Record observed outcomes and remaining limits.


## Verified implementation

Implemented in f6ad401 and 67af97e. The phone's build 159 and 160 reports both resolve to `ActivityLog.computeHRVWindows` → `backfillMissingWindows` → the ContentView startup task. Both are FRONTBOARD watchdog kills with a ten-second allowance. This confirms that the build 160 store-opening fix did not address this specific main-thread backfill.

Regression tests failed before fixes (25 assertions), then passed with background serialization and the corrected settled predicate. Independent review found two further consistency defects: ignored migration-save failures and edits racing a background window writer. Real SwiftData regressions reproduced both (eight assertions); both now pass. Migration stops before advancing an uncommitted cursor/version. An edit or deletion waits asynchronously for the current maintenance pass; follow-up passes wait until the edit finishes. This can delay the save while a current pass completes, while keeping the main thread available.

The final simulator suite passed **1,984 tests, two existing opt-in skips, zero failures**, exit 0 and TEST SUCCEEDED. It includes 20,000 synthetic samples plus 100 already-settled empty activities, preserving samples and valid missing-data windows. No database reset, schema change, calculation-version bump, or user diagnostic export was needed.

Review rulings: physical startup and distribution are verified during release, not inferred from unit tests; historical equal-timestamp migration-cursor handling remains unchanged (an interrupted legacy migration can still skip an equal-start entry); damaged-store recovery remains outside this maintenance fix, which uses the existing container without replacement. No unresolved Important/Critical findings or deferred Minor findings remain.


## Physical validation follow-up: Health projection

The development install of 5c046f6 on the existing iPhone store was killed after launch on 2026-11-22 at 07:56:30. This is not a functional pass. The new watchdog stack is `HealthSyncCoordinator.bootstrap` → `refreshView` → `HealthActivityProjector.project` → `ActivityLog.computeExerciseResponse` → `reserveSpan`, on the main thread. TestFlight publication is withheld.

Implementation follow-up: make Health projection metadata-only on an explicit serial background queue with a fresh ModelContext. New or changed windows remain unsettled; the environment-owned activity maintenance coordinator fences projection against ongoing calculations, then schedules repair. Existing settled results and all Polar samples remain intact. Regression coverage must prove metadata commits before calculation, changed windows invalidate, unchanged imports preserve summaries, and a fenced projection eventually receives background Polar results. Run focused/full tests, then install through ship.sh phone and verify the actual app survives launch before TestFlight.

Follow-up verification: the metadata-first regression failed with three assertions on the original projector and passed after the change. Thirteen focused Health/maintenance tests passed. The full signed simulator suite passed **1,986 tests, two existing skips, zero failures**, exit 0 and TEST SUCCEEDED (`/private/tmp/wythin161-health-full.log`). The new integration regression holds an old writer in flight, changes a Health workout interval, then verifies automatic repair yields the new interval's real Polar heart rate while retaining the raw sample. Physical revalidation and publication remain pending.
