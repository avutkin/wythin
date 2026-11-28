# Garmin HRM-Pro Plus implementation plan

> Execute with superpowers:executing-plans, test-driven-development and a fresh final code review.

**Goal:** Discover, select, reconnect and record from Garmin HRM-Pro Plus alongside Polar H10.

**Design:** Extend the existing strict device allowlist to these two models. Keep the existing CoreBluetooth lifecycle and shared Bluetooth Heart Rate Measurement parser and metric pipeline. Separate model capabilities so Garmin never starts Polar PMD or claims ECG/motion support. Preserve saved Polar pairing and last-selected device behavior; no automatic connection to an unfamiliar nearby sensor, including WHOOP or Garmin watches.

**Approaches:** Direct Bluetooth is the existing app architecture and matches the user's request. Garmin Connect/cloud import would not provide this live connection. Opening every heart-rate device would undo the user's explicit WHOOP exclusion. No new SDK or dependencies.

**Scope:** HRM-Pro Plus from the supplied photo only; HR/RR live acquisition, derived HRV, optional standard battery. No claim of raw ECG/ACC, proprietary running dynamics or offline Garmin-memory download. RR is optional in the Bluetooth standard; never fabricate intervals if absent. Physical validation requires the actual strap.

**Sources:** Garmin HRM-Pro Plus product specs (garmin.com.sg/products/intosports/hrm-pro-plus/), Garmin pairing manual GUID-26E43680-74CC-4CC7-946F-D5019AF632E4, Bluetooth HRS v1.0. Source inspected 2026-11-27.

**Files:** BLEService.swift (identity, saved pairing, capability/recovery gates, battery); LiveView.swift, OnboardingScreens.swift, SettingsView.swift and PolyvagalState.swift (accurate device copy); Info.plist/project.pbxproj (Bluetooth permission rationale); BLETests.swift (regressions, including real DataBuffer/MetricsEngine integration). Reuse existing file registration.

## Review focus

- Fresh advertisements override stale cached/verified names; unsupported watches remain rejected.
- Both device models remain visible after connection; last selected identity survives relaunch and switching clears old samples.
- Garmin's absent PMD does not cause retries or false UI stream claims; Polar recovery stays intact.
- RR-only data reaches the existing metric calculation/storage path without inventing ECG/ACC metrics.
- Battery instructions use CR2032 for Garmin and CR2025 for H10; nil contact/battery are supported.

## Tasks

- [x] Baseline: BLETests green before changes.
- [x] Add identity/discovery/pairing regressions; witness Garmin failures, generalize model allowlist with existing Polar cache keys retained.
- [x] Add model-capability and RR-only regressions; gate service requests/PMD, update connection UI and onboarding.
- [x] Run focused then full WythinTests, review whole diff, address material findings.
- [x] Commit, integrate on current main and publish through tools/ship.sh using the already-authorized TestFlight/external workflow.

## Evidence and decisions

- The current app accepts only Polar H10 by name; both models share standard 0x180D/0x2A37 HR/RR. Garmin documents BLE HR and HRV support, but no public Polar PMD-compatible ECG/ACC protocol.
- Existing main at start: 96cc2a2 (build 161). Use a dedicated managed worktree, leaving all other sessions intact.
- No design approval round: user explicitly requested this bounded extension; implementation choices remain within their authorized scope.

## Verification

- Baseline: 150 BLE tests passed. Initial three Garmin identity/discovery/pairing regressions failed with 15 assertions before implementation; the shared packet-to-HRV integration was already green.
- Independent read-only review found three material issues: BPM-only Garmin causing RR reconnect loops, authoritative unsupported advertisements not cancelling an already selected target, and optional battery discovery errors cancelling a healthy HR connection. All addressed. Also corrected Settings and the active Bluetooth permission rationale.
- Review regressions reproduced BPM-only and optional-battery failures before fixes. Positive BPM without any RR ever seen now keeps Garmin's HR link alive; after RR has once flowed, a subsequent RR outage retains recovery/continuity reset. Polar recovery behavior is unchanged.
- Garmin never enters Polar's in-place PMD standby. A real RR gap of 10 seconds or more clears the old tachogram before forwarding the first resumed beat; tested with DataBuffer generations. Explicit disconnect remains authoritative.
- Fresh unsupported identity on the active UUID now cancels that connection and emits a recording gap. Non-target discoveries remain ignored without disturbing other apps' connections. CoreBluetooth cancellation is code-reviewed; physical callback timing is not simulated by these unit tests.
- Full WythinTests: **1998 executed, 2 skipped, 0 failures**, including **161 BLE tests**; log `/private/tmp/wythin-garmin-full.log`. `git diff --check` and both property-list validation checks passed.
- Physical HRM-Pro Plus discovery, actual firmware RR/battery/contact availability and background reconnection still require the real strap. Standard packets in tests are synthetic, not a claimed hardware capture. No raw ECG/ACC or offline Garmin store-and-forward support is claimed.
- Release authorization follows the existing request to publish TestFlight and make it available externally. ASC confirmed build 161 is the current high-water mark and the existing External Testers public link remains enabled.

## Released 2026-11-27

- Implementation commit `1f9ef5f` integrated into main. `tools/ship.sh testflight` ran the full suite again: 1998 tests, 2 skipped, 0 failures. The two opt-in background upload smoke tests require a local receiver and external background action; both standard full runs skipped these unchanged tests.
- Release checks were slower under concurrent simulator workload. A process sample showed SwiftData history calculation making progress; the complete suite finished successfully without bypasses or test changes.
- **TestFlight build 162**, ASC build ID `6622a13d-22ab-46d9-980b-5643c492eeb7`: processing `VALID`, not expired, internal and external states both `IN_BETA_TESTING`.
- Assigned to **External Testers**, public link enabled and no tester limit: https://testflight.apple.com/join/7c7b68t1 . English and Russian release notes saved; automatic tester notifications enabled. Beta App Review submission accepted.
- Archive/export both succeeded. Actual archived bundle confirms build 162 and the Bluetooth permission explanation naming both Polar H10 and Garmin HRM-Pro Plus.
- Logs: `/private/tmp/wythin-garmin-ship.log`, `/private/tmp/wythin-ship-tests.log`, `/private/tmp/wythin-ship-archive.log`, `/private/tmp/wythin-ship-upload.log`.
- Public-link availability is verified; installation and a physical Garmin session on a tester's phone are not claimed.
