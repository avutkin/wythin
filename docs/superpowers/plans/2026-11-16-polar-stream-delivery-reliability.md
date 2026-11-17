# Polar stream and delivery reliability implementation plan

> **For agentic workers:** Use the agreed research report as the specification. Execute the independent BLE and delivery repairs with bounded file ownership; integrate and review the complete change before release.

**Goal:** Restore useful RR/ECG collection after same-iPhone app interference, deliver saved metrics without another sensor tick or foreground opening, and export actionable diagnostics for every user.

**Architecture:** Keep the existing CoreBluetooth connection owner. Track valid RR and both PMD streams independently; repair only stalled streams and reject obsolete work. Persist metric upload payloads as files and hand them to a system background URLSession, with durable acknowledgement and retry state. Keep diagnostic logs bounded and combine capture, BLE, upload and build/lifecycle metadata in one export.

**Tech Stack:** Swift, CoreBluetooth, SwiftData, Foundation background URLSession, XCTest; existing iOS deployment target and dependencies.

**Spec:** `docs/superpowers/specs/2026-11-16-polar-stream-delivery-reliability-design.md`, priorities selected by the user on 2026-11-16. The detailed private research report remains local. Kt Kt is evidence for analysis, never an account-specific feature flag.

## Global constraints

- Work only in this existing isolated checkout; preserve unrelated research artifacts.
- All users get the changes under existing monitoring and cloud-sync consent settings.
- No invented Bluetooth priority, periodic reset of a healthy link, forced eviction, or foreground-only recovery.
- No global raw ECG archive, ASK migration, H10 offline-recording experiment, server deployment, or unrelated metric formula change in this release.
- Distinguish simulator/policy coverage from physical locked-iPhone/H10 evidence. Do not claim a 72-hour physical test without performing it.
- Keep data until server acknowledgement; respect disabling sync; preserve existing metric/profile payload compatibility and historical cursor migration.
- Full WythinTests green before integration. Only `tools/ship.sh testflight` may archive/upload. Existing authorization covers main integration and external TestFlight availability.

## Review focus

- ECG alone stops while valid RR and ACC continue; recovery must execute on BLE events while backgrounded and preserve healthy RR.
- Invalid/old RR, delayed PMD callbacks and asynchronous computations must not generate apparently fresh samples.
- Final saved sample followed by sensor silence, offline network or process restart must remain deliverable without another RR tick.
- Partial/invalid server receipts, opt-out, cancellation and retries must never drop durable unsent data or silently advance acknowledgements.
- Diagnostic export must include capture and delivery status, remain bounded, and omit credentials/raw physiological payloads.

### Task 1: Repair RR/ECG recovery (independent BLE owner)

**Files:** `ios/Wythin/BLE/BLEService.swift`, `ios/WythinTests/BLETests.swift`.
**Interfaces:** Preserve existing subjects and live timestamps. Introduce shared `RRSignalValidity.isValid(_:)` for the existing 300...2000ms accepted range; root integrates buffer filtering. Expose a monotonically increasing recording generation on gaps if needed; root owns AppEnvironment/DataBuffer integration.

- [x] Write regression tests for invalid RR health, ECG-only stall, selective retries, bounded slow retry, stale recovery work and cancelled recovery; run to demonstrate failure.
- [x] Add ECG-specific PMD recovery, invoke maintenance on accepted BLE events and lifecycle checks; ensure off-body/manual stop/system reconnect still own their states.
- [x] Guard delayed PMD actions with connection/session identity; remove unconditional initial STOP of both healthy streams where safe; never issue endless command storms.
- [x] Run targeted BLE tests and record evidence; final shared suite is run by coordinator.

### Task 2: Durable independent metric delivery (independent sync owner)

**Files:** `ios/Wythin/Sync/APIClient.swift`, new `ios/Wythin/Sync/MetricUploadQueue.swift` if useful, new `ios/WythinTests/MetricUploadQueueTests.swift`; preserve existing `MetricSyncBacklogTests` compatibility or update them to assert the new durable behaviour.
**Interfaces:** Keep `MetricSyncService.syncIfEnabled() async`, `lastUploadedAt`, `lastError`; add `start()`/`savedMetricsDidChange()`/`applicationDidEnterBackground()` as necessary, plus static background session routing analogous to RawChunkSyncService. Coordinator owns AppEnvironment, NudgeRouting, project registration and diagnostics integration.

- [x] Test durable final-tail queuing/reopen, failed uploads/retry without new measurements, valid and invalid receipts, duplicate callbacks, consent cancellation, catch-up backlog and cursor migration before implementation.
- [x] Persist immutable upload batches before scheduling background file uploads; reconcile pending tasks across relaunch, acknowledge atomically, and keep failures queued with bounded retry.
- [x] Use independent network/lifecycle/retry triggers while execution is permitted and background-session completion for continued backlog; retain existing profile sync.
- [x] Verify captured timestamps/timezones and Stress Balance survive delivery unchanged; never embed auth in exported diagnostics.

### Task 3: Integrate freshness and unified diagnostics (coordinator)

**Files:** `ios/Wythin/App/AppEnvironment.swift`, `ios/Wythin/App/NudgeRouting.swift`, `ios/Wythin/BLE/DataBuffer.swift`, `ios/Wythin/UI/Settings/SettingsView.swift`, `ios/WythinTests/MetricsTests.swift`, project registration and focused diagnostic tests.
**Interfaces:** Consume Task 1 validity/generation and Task 2 scheduling/routing. Capture audit exports a locked snapshot; diagnostics combine build/OS/phase and per-stream/save/upload state into a single shareable text file.

- [x] Test ordered buffer generation handling and rejection of pre-gap computations/invalid-only RR; implement generation checks through ingest, snapshot and commit.
- [x] Schedule metric delivery only after successful durable save, independently flush on background and route system completion handlers at app launch.
- [x] Test diagnostic snapshots contain capture/failed-save and delivery evidence, report missing/error sections, and contain no credentials or raw sensor payloads; update existing Settings action.
- [x] Run targeted tests and complete suite, inspect current code diff and obtain fresh whole-branch review.

### Task 4: Verification and release

- [x] Run full simulator suite with absolute Xcode project path; exercise app background lifecycle and available system background upload path separately from physical BLE.
- [x] Inspect device availability and collect non-destructive physical evidence if possible; explicitly document hardware/other-app and long-duration limitations.
- [ ] Commit scoped code/docs/tests, integrate on latest origin/main without touching other checkouts, push, and execute sanctioned TestFlight release script with tests.
- [ ] Verify processed build and external testing state via App Store Connect, provide build number, changes, evidence and remaining physical validation.

## Execution record

- Baseline commit: `3646767`; latest TestFlight before work: 149 VALID. Existing phone is reachable but currently on 147; no claim of updated physical validation.
- Design/priority authorization: user's explicit instruction to implement the selected report priorities for everyone and prepare TestFlight; no further approval round needed.
- Concurrency decision: BLE and delivery fixes have disjoint file ownership; coordinator handles shared integration, build registration and final checks. Test simulator/build commands are serialized.
- Baseline fresh full suite: 1,761 tests, zero failures (`/private/tmp/wythin-reliability-baseline.xcresult`).
- Actual XCTest RED: invalid-only RR health, older RR clock, ECG-only stall, partial receipt and skipped valued receipt (`wythin-reliability-red.xcresult`).
- First integrated run: 157 tests, only the intentional capture-time timestamp regression failed. All initial delivery and BLE fixes passed; timestamp fix then applied (`wythin-reliability-integration1.xcresult`).
- Actual source Swift harness RED→GREEN: generation-safe ingest/reset, stale metric rejection, valid-RR audit and export, credential redaction; selective waveform resume separately RED→GREEN.
- Review accepted three concrete issues: notice opt-out cancellation, restored suspended upload resume, and monotonic BLE event ordering after clock rollback. All require regression coverage before release.
- Ruling: add optional per-row cloudUploadState (legacy nil / pending 0 / acknowledged 1) rather than rely on a moving timestamp cursor, because late/new equal-time rows otherwise disappear from delivery. Cloud-restored rows initialize acknowledged; old rows use a frozen migration boundary.

- Final full suite: **1,810 tests, 1 opt-in smoke skipped, zero failures**, exit 0 (`/private/tmp/wythin-reliability-full2.xcresult`). Includes 132 BLE tests and 8 delivery lifecycle tests. The two initially failing restoration fixtures were corrected to use a coherent retry clock and an actually registered, suspended system task; assertions verify the original task completes without cancellation.
- All review findings resolved: every sync consent path cancels outstanding work; restored suspended tasks resume; BLE ordering/recovery and metric throttling use monotonic uptime. Clock rollback regression was separately observed RED→GREEN before the final suite.
- Opt-in background system transport: **1 test, zero failures**, exit 0 (`/private/tmp/wythin-reliability-background.xcresult`). The simulator app was externally backgrounded before scheduling a real background URLSession file upload. A loopback receiver acknowledged one saved metric; the test verified the app stayed backgrounded and the persisted row became acknowledged. The fixture was removed afterward. This verifies system file transport while backgrounded, not process termination/relaunch, physical BLE or a 72-hour run.
- Physical limits: an iPhone was reachable at the initial audit, but no worn H10 plus competing ECG app was confirmed. No physical same-phone contention or multi-day monitoring result is claimed. The added diagnostics and TestFlight build support that follow-up.
