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
- UI/history work must not run on background cold start; cancellation must not poison the next foreground pass.
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

- [ ] Baseline existing BLETests/AppStartupTests.
- [ ] Add regressions for intent after reopen, legacy pairing, explicit stop/resume, saved advertisement after picker stop, wrong device rejection, inactive radio/connected states.
- [ ] Run regressions RED, implement durable intent and recovery scan wiring, run focused suite GREEN.
- [ ] Commit the isolated change.

### Task 2: Defer foreground-only history/display work

Files: ios/Wythin/App/AppEnvironment.swift; existing ios/Wythin/App/AppStartup.swift for a reusable foreground task owner if needed; ios/WythinTests/AppStartupTests.swift.
Interfaces: lifecycle-owned foreground work with async cancellation, one active generation and retry on next foreground. AppEnvironment starts/cancels display and warm-up work using the same owner; history's first load is always last 24 hours, even with a populated live buffer.

- [ ] Write async regressions: background creates no job, repeated foreground does not duplicate, background cancels suspended work, late completion cannot clear next job, re-entry retries incomplete preparation.
- [ ] Run RED; route loadHistory/rollups/prewarm/display through foreground lifecycle. Preserve baseline invalidation and capture path.
- [ ] Focused GREEN and full WythinTests suite, independent review, address important findings with regression tests.
- [ ] Record commands/results, commit; leave a reviewable patch and the full architecture proposal.

## Execution ledger

Pre-flight: Task 1 and Task 2 share AppEnvironment's call to BLE.ensureAutoConnect only; no changed signature. Implementation is inline. Ruling: existing authorization to fix reversible recovery behavior is sufficient to proceed; hardware/permission migrations remain proposed, not silently enabled.
