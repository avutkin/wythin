# Bluetooth recovery implementation plan

> Execute inline using superpowers:executing-plans, then request one whole-change review.

**Goal:** Resume recording after RR stalls or standby without opening the app.
**Architecture:** Pure recovery state in BLEService.swift, driven directly by BLE events and supplemented by the existing watchdog. Reuse persistent pending connection and gap reset machinery.
**Tech stack:** Swift, CoreBluetooth, XCTest.
**Spec:** ../specs/2026-11-16-ble-background-recovery-design.md

## Constraints and review focus

Respect manual disconnect, suppress reconnect storms, do not misclassify fresh off-body beacons, ignore callbacks from a canceled/previous connection, preserve background restoration. No shipping or edits to other sessions' worktrees.

## Task 1: RR recovery and background wiring

- [x] Add BLETests covering PMD-only event inputs, HR without RR, healthy RR, off-body beacon expiry, total silence, retries/cooldown, stale timestamps and fresh connection grace. Run to observe failure.
- [x] Implement RRStreamRecovery with begin/end, HR/packet event inputs and actions wait/probe/refreshHeartRate/reconnect; use 15/10/30/60-second thresholds from the spec.
- [x] Wire actions to HR notification refresh and cancel→didDisconnect→persistent connect. Keep standby watchdog active; reset liveness on disconnect. Evaluate on BLE events and app phase changes.
- [x] Run BLETests, then full WythinTests with absolute project path and isolated derived data. Review all failures.
- [x] Independent review and final diff verification. Record physical-device test limits and a concrete locked-screen procedure.

## Progress

Baseline: 83 BLE tests passed. New policy tests initially failed compilation because RRStreamRecovery was absent; after implementation all 95 BLE tests passed. Review requested command-boundary coverage: five additional tests cover disable→ack→enable, already-disabled HR, discovery, cancellation and disconnect reset. Those failed before RRRecoveryCommands was implemented. Full suite then passed 1719 tests.

Review also identified missing RR continuity reset when subscription refresh succeeds without a disconnect. Added ordered clear-gap command expectations, observed the old command contract fail compilation, then implemented clear-gap before refresh. Final full suite: **1719 tests passed, zero failures**, including 100 BLE tests (17 added). `git diff --check` passed. Xcode retains the pre-existing duplicate MetricNamingTests.swift build-file warning.

Final command: `xcodebuild test -project /Users/alexutkin/Code/Wythin/.claude/worktrees/ble-background-recovery/ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,id=3642B670-480A-4DAC-A598-19411350B62D' -derivedDataPath /tmp/wythin-ble-recovery-derived -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO`. Output: `/tmp/wythin-ble-recovery-full.log`.

No connected iPhone was available according to `xcrun devicectl list devices`. Automated verification covers policy/event inputs and generated command sequences. It does not simulate OS suspension, execute a real CoreBluetooth reconnect, or prove physical background recording.

## Physical validation still required

Use the project's shipping path after integration; do not install an isolated feature build over the user's released app.

1. Wear H10, establish RR/ECG/ACC recording, background and lock iPhone. Keep it locked during every transition below.
2. With a controlled BLE test peripheral, keep PMD flowing but suppress RR (including HR packets with BPM and no RR). Expect `RR recovery HR notify=... background=true`, followed by resumed recording; if unresolved, `RR recovery reconnect background=true`, `DISCONNECT unexpected`, `CONNECT pending`, and `CONNECTED`. Confirm persisted metric timestamps after the gap without foregrounding the app.
3. With the actual H10, remove it until standby, then put it back on. Confirm STANDBY resume or pending reconnect and new persisted samples. Also power the H10 off/on or take it out of range and back while the phone stays locked.
4. Exercise OS restoration separately: pending connection/subscription must restore in the background. A user force-quit is not a restoration test.
5. Explicitly disconnect, then allow delayed notification/disconnect events: verify there is no unsolicited restart.

Ruling: implementation stays in this isolated worktree; no merge, push or device installation was requested. The physical checks remain open, not reported as passed.

## Follow-up: Kt Kt on build 147

The screenshot reports recording only after manually opening the app and names build 147. Verified release commit `eaf84db`: it still has the old state-only watchdog and cancels that watchdog at standby entry. This fix was not shipped in 147.

Read-only production check on November 16 (user's chart reference zone: Australia/Sydney): stored samples form runs on Nov 14 08:08–14:19, Nov 16 14:27–16:04, and Nov 17 from 07:32 onward. At the check the latest sample was Nov 17 08:37 Sydney (Nov 16 21:37 UTC). The Nov 16 16:04 Sydney points reached the server only Nov 17 07:32 Sydney, about 15h28m later, alongside a recorded foreground opening. This proves delayed upload for those points; it does not prove whether other missing intervals were caused by a stalled stream, app termination, strap removal or disabled connectivity. The initial empty-today screenshot was taken near the next run's start.

Request `Settings → Share Bluetooth diagnostics` from Kt Kt to identify the actual local stop reason. No direct message was sent. Prepare the existing fix on current origin/main and rerun the full suite before requesting release authorization. Do not claim this patch addresses delayed network uploads or proves physical background recovery.

Release preparation completed: code commit `d4dac23` rebased onto `origin/main` at `0cf1262`; final full suite **1746 tests passed, zero failures**, and `git diff origin/main --check` passed. `tools/ship.sh status` confirms TestFlight 147 is the latest VALID build and the paired iPhone is unreachable. No main push or TestFlight upload performed. Release approval and physical-device verification remain outstanding.
