# Startup Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove destructive/forced startup failure handling and keep history reloads off the main thread, then ship a tested update.
**Architecture:** Async observable startup state creates the existing environment only after a disk container succeeds. A coalescing history loader publishes bounded value snapshots to the main actor.
**Tech Stack:** SwiftUI, SwiftData, UIKit, XCTest; iOS 17 minimum.
**Spec:** docs/superpowers/specs/2026-11-21-startup-recovery-design.md

## Global Constraints

- Keep the existing SwiftData schema, store path and sidecars. Never rename/delete/reset a user's store on an open error.
- Start without a view appearing, including background relaunches; one environment per successful startup.
- Existing chart gap fix, Bluetooth recovery, consent gates, and upload queues remain intact.
- Only synthetic fixtures in tests; no profile queries or third-party diagnostics services.
- Full signed suite, independent review, main integration, tools/ship.sh testflight, existing authorized external testers.

## Review Focus

- A protected or out-of-space store must remain byte-for-byte where it was and show retryable failure (Task 1).
- Retry and duplicate starts must not create two environments or replay startup side effects (Task 1).
- Background restoration must initialize without a visible scene; phase updates arriving before ready must not be lost (Task 1).
- Live arrivals while history reads must survive without duplication, including a full 43,200-point result (Task 2).
- Restore/invalidation during a read must prevent obsolete results from returning (Task 2).

### Task 1: Preserve storage and expose recoverable startup

**Files:** Create ios/Wythin/App/AppStartup.swift and ios/WythinTests/AppStartupTests.swift; modify ios/Wythin/App/WythinApp.swift and ios/Wythin.xcodeproj/project.pbxproj.
**Interfaces:** AppStoreBootstrap.schema and open(configuration:makeContainer:) throws -> ModelContainer; AppStartup<Value> with value, error, isLoading and start(); production async container open on a detached worker.

- [ ] Extract the existing open policy as a behavior-preserving seam; write a failing regression that simulates one opening failure followed by a usable empty fallback and asserts the original store/sidecars were not moved and the failure is propagated.
- [ ] Run focused test; Expected: FAIL because existing code relocates storage and returns a replacement container.
- [ ] Replace relocation/forced reopen with one throwing open. Add an observable async loader, retry on protected-data availability after failure, and opening/retry UI. Start from App init independently of scene appearance; attach environment/Health once; apply latest scene phase when ready.
- [ ] Test actual store failure, retry after failure, coalesced starts, successful background-style initialization without view, and nonblocking container creation. Expected: PASS.
- [ ] Run focused startup tests and existing schema migration tests; commit.

### Task 2: Coalesce background history reads and verify release

**Files:** Create ios/Wythin/App/RecentHistoryLoader.swift and ios/WythinTests/RecentHistoryLoaderTests.swift; modify AppEnvironment.swift and project.pbxproj; retain ChartSegmenterTests render diagnostic.
**Interfaces:** RecentHistoryLoader requests a read from a supplied lower timestamp and bounded count, coalesces requests, supports invalidation, and delivers a merge of value snapshots without reading a ModelContext on main.

- [ ] Write failing tests for concurrent live arrivals, duplicate timestamps, newest-point bound, responsive main actor during real worker execution, repeated reload requests and invalidation. Expected: FAIL against absent/unbounded/synchronous behavior.
- [ ] Implement one worker-owned ModelContext reader, bounded merged history, coalescing and generation invalidation. Wire launch and foreground through it; remove synchronous main-context history fetch.
- [ ] Run focused tests and full WythinTests. Expected: PASS, existing two opt-in skips permitted. Commit.
- [ ] Independent final review; fix important findings with failing tests first. Verify full suite after fixes.
- [ ] Integrate into main and ship via tools/ship.sh testflight. Check processing, review, tester assignment. Report exact verification limits; do not claim the original device exception was identified.


## Verification record — 21 November 2026

Implemented in 95f680b, 714afbb and 45230ea, with concurrent main documentation preserved in a62b38e. A fresh reviewer identified five Important lifecycle/performance findings; all were addressed in one regression-driven pass. Tests reproduced failure/expiration callback leaks, missing background execution allowance, duplicate phase delivery, a lost unlock during store opening, and unnecessary publication after an empty history read. The focused run passed 21 tests after the fixes. The full merged simulator suite passed 1,978 tests with two existing opt-in skips and zero failures (`TEST SUCCEEDED`, exit 0).

The store-open policy no longer moves database/sidecar files or force-opens an empty replacement. Disk opening and recent-history reads happen off the main actor. Live samples take precedence over overlapping disk snapshots, reads coalesce, and invalidated reads cannot republish old history. Background startup acquires a bounded UIKit task before yielding; success, failure and expiration release it exactly once. Upload wake callbacks are released on startup failure/expiration without changing durable upload queues. Unlocks received during opening trigger one retry if that attempt fails.

The observed build 159 failure on Alex's physical phone still has no available exception stack. These tests establish specific startup failures and their fixes, not proof of the exact device exception or uninterrupted overnight H10 recording. Physical-device validation remains outstanding.

Deferred minor review item: the recovery-screen snapshot uses a light ImageRenderer environment; verify a hosted dark-mode capture and button contrast. The production app window already requests dark mode. No declined-to-judge findings or unresolved Important/Critical findings remain.
