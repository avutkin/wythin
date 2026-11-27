# Recording resilience implementation plan

> Execute inline using superpowers:executing-plans and test-driven-development; one independent whole-change review.

**Goal:** Keep saved-device reconnection armed and remove UI-only startup load from background recording.
**Architecture:** Extend the existing pairing/recovery state machine; lifecycle-owned foreground work with cancellation and generation fencing. Preserve capture, metrics, persistence and uploads.
**Tech stack:** Swift, CoreBluetooth, SwiftData, XCTest.
**Spec:** ../specs/2026-11-27-recording-resilience-design.md

## Global constraints

- No metric/schema/cadence changes, raw archive enablement, production changes, or external release.
- Only reconnect the saved verified H10. Explicit Disconnect wins across process restart.
- Background recovery scan uses HR/PMD services and no UI timeout. A scan is fallback when no cached peripheral is available; pending connect stays preferred.
- UI rollup/dashboard/display work must not run on background cold start; cancellation must not poison the next foreground pass. Recording-owned history remains bounded and available in background for anchor detection (review adjustment below).
- Simulator tests do not establish physical-device uptime or lossless capture.

## Review focus

- Legacy pairing with no new intent flag retains reconnect; a forgotten/unsupported device is never selected.
- Manual scan, Stop Scan, disconnect, poweredOff/poweredOn and restored scanner must not leave conflicting recovery modes.
- Delayed advertisements cannot reconnect a different sensor or override explicit stop.
- A backgrounded warm-up cannot publish stale work into a newer foreground/timezone pass.
- First foreground must still load the full day, including data older than samples accumulated in the background.

### Task 1: Preserve reconnection intent and saved-device rediscovery

Files: ios/Wythin/BLE/BLEService.swift; ios/WythinTests/BLETests.swift.
Interfaces: PolarH10Pairing.autoConnectEnabled + setAutoConnectEnabled(_:); BLEDiscoverySession recovery mode with saved UUID selection separate from visible device enumeration. BLEService owns the CoreBluetooth scan operation.

- [x] Run BLETests/AppStartupTests. Initial run included new regressions and failed to compile against old interfaces; no separate clean pre-change baseline is claimed. Compatibility is covered by the focused and final full runs below.
- [x] Add regressions for intent after reopen, legacy pairing, explicit stop/resume, saved advertisement after picker stop and wrong device rejection; retain existing connection-state coverage.
- [x] Run regressions RED, implement durable intent and recovery scan wiring, run focused suite GREEN.
- [x] Commit the isolated change (`c33f2da`), followed by the review corrections with Task 2.

### Task 2: Defer foreground-only preparation/display work

Files: ios/Wythin/App/AppEnvironment.swift; existing ios/Wythin/App/AppStartup.swift for a reusable foreground task owner if needed; ios/WythinTests/AppStartupTests.swift.
Interfaces: lifecycle-owned foreground work with async cancellation, one active generation and retry on next foreground. AppEnvironment starts/cancels display and warm-up work using the same owner; recording history still loads in background and its first load is always last 24 hours, even with a populated live buffer.

- [x] Write async regressions: background creates no job, repeated foreground does not duplicate, background cancels suspended work, late completion cannot clear next job, re-entry retries incomplete preparation.
- [x] Run RED; route rollups/prewarm/display through foreground lifecycle. Preserve recording history, baseline invalidation and capture path.
- [x] Focused GREEN and full WythinTests suite, independent review, address important findings with regression tests.
- [x] Record commands/results, commit; leave a reviewable patch and the full architecture proposal.

## Execution ledger

Pre-flight: Task 1 and Task 2 share AppEnvironment's call to BLE.ensureAutoConnect only; no changed signature. Implementation is inline. Ruling: existing authorization to fix reversible recovery behavior is sufficient to proceed; hardware/permission migrations remain proposed, not silently enabled.

Review adjustment: `tickHistory` is shared with `detectAnchorIfDue`, so deferring or canceling its required initial read would change frozen anchors after a background relaunch. Retain the original bounded asynchronous recording-history load, including background publication and `rewarmAfterRestore`; only rollups/dashboard/display are foreground-owned. Invalidated history reads still drain serially. This intentionally narrows the first-stage optimization to preserve metric behavior.

Evidence so far: initial new BLE regressions failed to compile against the old interfaces; first implementation passed 154 BLE/AppStartup tests (`/private/tmp/wythin-resilience-ble-green.log`). The history overlap regression failed behaviorally with two simultaneous reads instead of one (`/private/tmp/wythin-resilience-history-red.log`); after fixing ownership, 181 focused tests passed (`/private/tmp/wythin-resilience-focused-green.log`). Whole-change review found scan-only restoration, downstream dashboard cancellation, and recording-history ownership boundaries; fixes and final full-suite evidence follow.

## Final verification — 2026-11-27

Review corrections: recovery intent initializes before CBCentralManager, and both poweredOn and scanner-only restoration reconcile without requiring a peripheral or scene callback. DayPotential backfill readiness fences cancellation and permits retry; late narrative results also check cancellation/day/timezone. Recording history remains available in background. Unchanged reconnect preference values no longer generate repeated UserDefaults writes. Additional regressions initially failed to compile against the missing interfaces (`/private/tmp/wythin-resilience-review-red.log`) and passed in the final suite.

Independent re-review: all three important findings and the minor repeated-write finding resolved; no unresolved significant issues. Physical reconnection/relaunch/battery guarantees, KT's termination cause and future journal/H10/ASK/MetricKit implementation remain explicitly unverified/out of this patch. They are preserved in the architecture proposal, not silently dropped.

Final command (exit 0, `TEST SUCCEEDED`):

```sh
xcodebuild test \
  -project /Users/alexutkin/.codex/worktrees/recording-resilience/Wythin/ios/Wythin.xcodeproj \
  -scheme Wythin \
  -destination 'platform=iOS Simulator,id=13E49A03-B74A-4D83-80DF-994C88500356' \
  -derivedDataPath /private/tmp/wythin-resilience-build
```

Result: 1,996 tests, 0 failures, 2 opt-in skips (1,994 passed). The skipped RecordingBackgroundSmokeTests require a local receiver and an external action to background the host; no claim those integration scenarios ran. Full log: `/private/tmp/wythin-resilience-full.log`. Result bundle: `/private/tmp/wythin-resilience-build/Logs/Test/Test-Wythin-2026.11.27_15-36-51--0800.xcresult`. `git diff --check 96cc2a2` passed.

Integration: preserve the native managed worktree and local commits for review. No merge, production mutation, device install or TestFlight upload. This completes the authorized scoped code change and proposal; physical validation remains required before a continuity claim or rollout.
