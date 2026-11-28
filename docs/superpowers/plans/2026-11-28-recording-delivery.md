# Recording Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent processing delays from causing false stream recovery, false standby or unnecessary loss of admitted metrics, and make timezone evidence explicit.

**Architecture:** Keep receipt evidence independent of MainActor with active-characteristic and monotonic-clock fences. Separate history persistence from live result freshness. Retain the existing UTC and generation contracts.

**Tech Stack:** Swift, CoreBluetooth, SwiftData, XCTest; iOS 17+.

**Spec:** docs/superpowers/specs/2026-11-28-recording-delivery-design.md

## Global Constraints

- Preserve Polar H10 behavior and explicit user pause. Initial Garmin compatibility was superseded by the user-authorized Polar H10-only build 164 during release integration.
- No external release authorization, production writes, schema changes or fabricated data.
- Full WythinTests green before integration; isolated current worktree only.

## Review Focus

- Old characteristic callbacks after reconnect cannot suppress real recovery.
- One healthy PMD stream cannot hide a missing other stream or missing RR.
- Missing observations cannot accumulate off-body dwell across suspension.
- Delayed old-generation metrics cannot reach history or live presentation.
- Sydney DST/UTC day changes cannot alter capture instants or monotonic recovery.

### Task 1: Receipt liveness and standby continuity

**Files:** ios/Wythin/BLE/BLEService.swift; ios/WythinTests/BLETests.swift.
**Interfaces:** A lock-protected receipt tracker bound by stream/source/start uptime; `isLive` and receipt uptimes feed standby/RR/PMD recovery. Existing watchdog defaults remain compatible.

- [x] Add failing tests for a >10-second unobserved standby dwell and fresh receipts pending MainActor delivery; verify old sources, old uptimes, disconnect and independent outage behavior.
- [x] Run targeted BLETests and observe the failures.
- [x] Implement receipt tracker bindings at subscription/start and reset at stop/clear; consume positive liveness in recovery and standby, with bounded delay diagnostics.
- [x] Run targeted tests; included in the final verified commit.

### Task 2: Preserve delayed admitted metrics

**Files:** ios/Wythin/App/AppEnvironment.swift; ios/Wythin/BLE/DataBuffer.swift; ios/WythinTests/RecordingReliabilityTests.swift.
**Interfaces:** Result disposition distinguishes live, history-only and rejected windows using admission uptime, completion uptime, generation and connection state.

- [x] Add failing tests: a window fresh at admission persists at original capture time after a 30-second delay, is excluded from live output, and is rejected after generation/state change or stale admission.
- [x] Run the tests to observe failure; implement disposition and use it in the actual metrics loop; persist before optional work and record delayed/discard reasons.
- [x] Verify targeted tests; included in the final verified commit.

### Task 3: Unambiguous local diagnostics

**Files:** ios/Wythin/BLE/RecordingDiagnostics.swift; ios/Wythin/App/AppEnvironment.swift; ios/WythinTests/RecordingReliabilityTests.swift.
**Interfaces:** Export accepts a clock/timezone for deterministic formatting and reports canonical UTC plus local context and distinct uptime meanings.

- [x] Add failing Sydney November, winter and DST-boundary export tests, retaining UTC instants.
- [x] Verify failure; implement explicit timezone/offset/local date plus correctly named uptime fields, preserving bounded redacted export.
- [x] Run targeted and complete WythinTests, inspect failures and review whole change; included in the final verified commit.

## Execution ledger

- Baseline: 4ad57ff (build 163 internal release); clean isolated worktree.
- Native implementation authorized by the user's request to test and implement the fixes; no further design choice needed.
- Tasks share only the existing monotonic and generation contracts; preserve those during implementation.

## Verification and review evidence

- Task 1: standby dwell test failed at runtime on the old code (2 assertions); receipt tests initially failed to compile before the new contract existed. Targeted BLETests: 171 passed.
- Task 2: delayed-completion tests initially failed to compile without disposition; BLE + recording reliability: 182 passed.
- Task 3: timezone tests initially failed to compile without injected export clock/context; all 13 RecordingReliabilityTests passed including both Sydney DST boundaries.
- Initial complete WythinTests: 2038 executed, 2 skipped, 0 failures (`/private/tmp/wythin-delivery-full.log`).
- Final fresh-context review requested four corrections: receipt evidence must span the full RR timeout; delayed respiration candidates must not be stored as tracked rates; storage errors must not freeze independent live presentation; freshness must be rechecked after synchronous enrichment/save. All four corrections completed in the fix pass with runtime regression coverage.
- Ruling: keep one final commit for these tightly coupled delivery changes instead of task commits — review found boundary corrections spanning policies and the live loop; the worktree retains all test evidence until the final green suite.
- Ruling: hardware radio loss and OS termination cause remain unverified — this export contains no OS termination report or radio trace; guessing would risk replacing correct recovery behavior.

- Review fix pass: RR premature reset reproduced at runtime (1 failing assertion). Result-delivery effects extracted into the production MetricDelivery path; delayed respiration, failing store and slow store each reproduced at runtime (6 assertions across 3 tests). After corrections, BLE + recording reliability: 189 passed.
- Delayed respiration is omitted when temporal tracking is skipped; no raw candidate is promoted to a finalized historical rate. Save errors remain visible but do not suppress fresh live consumers. Live eligibility is checked again after persistence/history work.
- Additional compatibility boundary reproduced (4 runtime assertions), corrected and verified in the final suite: delayed healthy Garmin HR-only frames and normal Polar off-body beacons must not initiate recovery themselves; the independent watchdog still handles subsequent silence.

## Final verification

- Final full WythinTests: **2044 executed, 2 skipped, 0 failures** (2042 passed), 2026-11-27 19:10 PST.
- Command: `xcodebuild test -project /Users/alexutkin/.codex/worktrees/recording-resilience/Wythin/ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,id=13E49A03-B74A-4D83-80DF-994C88500356' -derivedDataPath /private/tmp/wythin-resilience-build -only-testing:WythinTests`.
- Full output: `/private/tmp/wythin-delivery-final-full.log`; `.xcresult` path recorded at its end.
- Skips: two existing opt-in upload/background smoke tests require a local receiver plus external app-background action; no claim of device endurance or background-upload smoke coverage in this run.
- `git diff --check` passes. Fresh reviewer had no additional findings in replacement/disconnect, independent PMD recovery, standby continuity, generation fences or Sydney formatting. All four Important findings fixed; no deferred minors.
- At implementation completion, changes were retained in the isolated development branch. The subsequent user request authorizes the TestFlight update recorded below; external group assignment remains a separate authorization boundary.

## TestFlight update integration

- User requested the TestFlight update after the implementation commit `234e7aa`.
- `origin/main` advanced to `ce96665`, incorporating the user-authorized removal of Garmin and build 164. Merged that current behavior, retaining all recording receipt/freshness fixes; no Garmin support is restored.
- Resolved three BLE signature/guard conflicts and adapted the added delayed healthy-frame regression to Polar normal RR plus standby beacons. Existing rejection/migration tests from build 164 remain unchanged.
- Fresh read-only integration review: no blocking code findings; superseded Garmin wording corrected in the plan/spec. Full suite runs before pushing, and the official ship script repeats it from origin/main.

- Polar-only integration full suite: **2039 executed, 2 existing opt-in skips, 0 failures**, 2026-11-27 19:18 PST; log `/private/tmp/wythin-delivery-polar-integration.log`.

## Build 165 release verification

- Integrated source: `fe6a297`; official `tools/ship.sh testflight` recorded build bump `85c467c` on `origin/main`.
- The release worktree repeated the full suite: **2039 executed, 2 existing opt-in skips, 0 failures** (2037 passed), 2026-11-27 19:20 PST; log `/private/tmp/wythin-ship-tests.log`.
- Official Release archive and upload succeeded. Archive metadata verifies `com.alexutkin.wythin`, version **1.1**, build **165**. App Store Connect accepted the upload at 2026-11-27 19:22 PST.
- Apple processing completed: build ID `b41861d7-ef2a-43c3-9113-68bb7d697cd4`, `processingState=VALID`, `usesNonExemptEncryption=false`. Official shipping script exited successfully.
- Fresh App Store Connect API verification confirms version **1.1 (165)**, Internal group assignment and `internalBuildState=IN_BETA_TESTING`. Russian and English release notes were saved and read back exactly.
- External state is `READY_FOR_BETA_SUBMISSION`; no external group assignment has been made in this release run. Explicit permission was requested under the repository's external-tester rule after the concrete internal release was ready.
- Release logs: `/private/tmp/wythin-delivery-testflight.log`, `/private/tmp/wythin-ship-archive.log`, `/private/tmp/wythin-ship-upload.log`. Final API verification: `/private/tmp/wythin-build165-final.json`.
