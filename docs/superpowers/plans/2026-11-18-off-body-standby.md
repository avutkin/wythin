# Off-body Standby Implementation Plan

> Execution: inline using superpowers:executing-plans, followed by one independent whole-change review.

**Goal:** Stop off-body ECG/ACC recording while preserving automatic resume and real overnight heartbeat capture.
**Architecture:** Correct the pure standby evidence policy, share a monotonic dwell gate with the callback-driven application path, and derive truthful Bluetooth presentation from current wear/liveness state.
**Tech Stack:** Swift, CoreBluetooth, Combine, SwiftUI, XCTest.
**Spec:** docs/superpowers/specs/2026-11-18-off-body-standby-design.md

## Global Constraints
Existing 5-second strong / 45-second borderline dwell. Live RR or plausible HR protects wear. Raw ECG alone does not. Keep HR connected in standby; retain resume thresholds and data/upload behavior. No physical H10 test claim.

## Review Focus
- Continuous off-body ECG packets with absent RR must not reset the dwell.
- A dry strap on a motionless sleeper must not pause with fresh RR/HR.
- RR subscription failure with unknown/on-body contact must remain recoverable, not become standby from ECG traffic alone.
- Connection generation changes or fresh wear evidence reset dwell.
- Cached quality/traces must not present off-body data as a current clean ECG.

### Task 1: Correct standby evidence and Bluetooth presentation
Files: ios/Wythin/BLE/BLEService.swift; ios/Wythin/App/AppEnvironment.swift; ios/Wythin/UI/Live/LiveView.swift; ios/WythinTests/BLETests.swift.
Interfaces: StandbyPolicy.offBodyScore adds heartbeatLive default false; StandbyEntryGate.shouldEnterStandby(score:connected:generation:uptime:) owns monotonic dwell; SkinContactPolicy.isOffBody(contact:rrLive:heartbeatLive:inStandby:) supplies current presentation; existing enterStandby/resume retain HR.
- [ ] Add and run regression tests demonstrating ECG-only liveness incorrectly blocks off-body entry and unknown contact incorrectly appears on skin.
- [ ] Correct policy, add the dwell gate and its reset/boundary tests, connect the application callback/poll path and retain independent recovery.
- [ ] Mask cached quality/waveforms when off-body; clear StreamScope at state transitions; test real publisher/reset behavior.
- [ ] Run focused BLE/reliability/quality/reporter tests, then full signed WythinTests with an absolute project path. Expect TEST SUCCEEDED, only existing opt-in skips.
- [ ] Commit, independent final review, fix any important findings with regression evidence, push and ship through tools/ship.sh testflight. Verify external build state and record evidence.
