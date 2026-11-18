# Off-body Standby Implementation Plan

> Execution: inline using superpowers:executing-plans, followed by one independent whole-change review.

**Goal:** Stop off-body ECG/ACC recording while preserving automatic resume and real overnight heartbeat capture.
**Architecture:** Correct the pure standby evidence policy, share a monotonic dwell gate with the callback-driven application path, and derive truthful Bluetooth presentation from current wear/liveness state.
**Tech Stack:** Swift, CoreBluetooth, Combine, SwiftUI, XCTest.
**Spec:** docs/superpowers/specs/2026-11-18-off-body-standby-design.md

## Global Constraints
Existing 5-second strong / 45-second borderline dwell. Live RR or plausible HR protects wear. Contact evidence expires after four seconds using its HR receipt uptime. Raw ECG alone does not. Keep HR connected in standby; retain resume thresholds and data/upload behavior. No physical H10 test claim.

## Review Focus
- Continuous off-body ECG packets with absent RR must not reset the dwell.
- A dry strap on a motionless sleeper must not pause with fresh RR/HR.
- RR subscription failure with unknown/on-body contact must remain recoverable, not become standby from ECG traffic alone.
- Connection generation changes or fresh wear evidence reset dwell.
- Cached quality/traces must not present off-body data as a current clean ECG.

### Task 1: Correct standby evidence and Bluetooth presentation
Files: ios/Wythin/BLE/BLEService.swift; ios/Wythin/App/AppEnvironment.swift; ios/Wythin/UI/Live/LiveView.swift; ios/WythinTests/BLETests.swift.
Interfaces: SensorContactObservation.current(at:) supplies age-qualified contact to BLE state, diagnostics and UI; StandbyPolicy.offBodyScore adds heartbeatLive default false; StandbyEntryGate.shouldEnterStandby(score:connected:generation:uptime:) owns monotonic dwell; SkinContactPolicy.isOffBody(contact:rrLive:heartbeatLive:inStandby:) supplies current presentation; existing enterStandby/resume retain HR.
- [x] Add and run regression tests demonstrating ECG-only liveness incorrectly blocks off-body entry and unknown contact incorrectly appears on skin.
- [x] Correct policy, add the dwell gate and its reset/boundary tests, connect the application callback/poll path and retain independent recovery.
- [x] Mask cached quality/waveforms when off-body; clear StreamScope at state transitions; test real publisher/reset behavior.
- [x] Run focused BLE/reliability/quality/reporter tests, then full signed WythinTests with an absolute project path. Expect TEST SUCCEEDED, only existing opt-in skips.
- [ ] Commit, independent final review, fix any important findings with regression evidence, push and ship through tools/ship.sh testflight. Verify external build state and record evidence.


## Verification before release

Initial reproduction: three tests failed five assertions for ECG-only veto, false inferred skin contact and retained scope. The first correction passed the entry policies but exposed two late-packet scope failures; those were fixed by state/wear admission. Focused checks passed 183 tests. The first full suite passed 1,950 tests with two existing opt-in skips.

Independent whole-change review found one important regression: an old negative contact bit could survive an HR subscription stall and stop a healthy ECG before RR recovery. Contact now expires four seconds after its monotonic HR receipt; both entry and presentation read the same observation. The new stale-contact/expiration regressions failed before the age guard and passed afterward; fresh off-body beacons still reach standby. Final signed full suite: **1,953 executed, 2 opt-in skips, 0 failures** (`/private/tmp/wythin-offbody-final-full.log`). No remaining review findings or deferred minors.

The existing tests cover stopped PMD startup/retry commands in standby, HR resume gates, and genuine-gap buffer handling. The callback/poll path uses no foreground-only metric or UI result. No physical H10 removal, battery-drain or locked-iPhone wake test was performed; simulator and pure callback tests do not establish those outcomes.

Decisions: implement and release under the user's continuing correction/update authorization; retain the lightweight HR link for automatic resume instead of a reconnect loop; release with the explicitly stated physical-device validation limit. Costs: the sensor is not physically powered off, and hardware-specific timing remains to be checked on the installed build.
