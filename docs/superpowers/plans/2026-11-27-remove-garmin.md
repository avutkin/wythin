# Remove Garmin support

**Goal:** Follow the user's decision to remove Garmin because raw ECG is unavailable through a confirmed interface. Polar H10 remains the only supported sensor.

**Design:** Restrict the shared identity policy to Polar H10; remove Garmin-specific capabilities, HR-only recovery exceptions and UI. On initialization, forget a saved identity positively identified as unsupported, preserving existing Polar pairings, unnamed legacy UUIDs and explicit pause intent. Retain all later recording-resilience changes and the generic battery-discovery and identity-rejection fixes.

**Scope:** `BLEService.swift`, `BLETests.swift`, connection/onboarding/settings views, permission copy, `PolyvagalState.swift`. Historical recordings and research remain intact. Existing onboarding questionnaire choices about other trackers are not connection support.

**Execution:** Implement in the current isolated worktree, review, run the full WythinTests suite, merge to main, then use `tools/ship.sh testflight` and the previously authorized External Testers group.

- [x] Add and observe failing regressions for rejecting Garmin aliases, saved Garmin migration, picker filtering and manual selection after disconnect.
- [x] Remove Garmin support while retaining all nearby H10s and reconnecting only to the last selected H10.
- [x] Run BLE tests, full WythinTests, plist validation and independent code review.
- [x] Merge, ship and verify processing plus external TestFlight eligibility.

## Verification evidence

- Baseline: `4ad57ff` (build 163), including the latest recording-resilience changes.
- Red: 4 new tests failed with 28 expected assertions against Garmin-enabled code (`/private/tmp/wythin-polar-only-red.log`).
- Green: all 161 BLE tests passed (`/private/tmp/wythin-polar-only-ble.log`).
- `git diff --check` and both plist validations passed.
- Initial full suite: 2024 tests, 2 existing opt-in background-upload skips, 0 failures (`/private/tmp/wythin-polar-only-full.log`).
- Review found a paused OS-restoration cleanup gap. Power-on now always reconciles restored peripherals; a paused session selects none, rejecting every restored connection. Physical CoreBluetooth restoration cannot be simulated by this suite.
- Final full suite after the restoration fix: 2024 tests, 2 existing opt-in skips, 0 failures; `TEST SUCCEEDED` (`/private/tmp/wythin-polar-only-full-final.log`).
- Independent read-only reviewer confirmed the fix; no remaining findings.
- Implementation merged as `8798996`; ship-generated build bump `f75f969`.
- Official `tools/ship.sh testflight` repeated the full suite: 2024 tests, 2 existing opt-in skips, 0 failures; archive and upload succeeded.
- Build **164**, version **1.1**, ASC ID `324b0103-dd38-43b7-b76a-bc2be64ecb9f`: `VALID`, not expired, export compliance set.
- English/Russian TestFlight notes updated. Assigned to **External Testers** (`94ee2df5-3500-412a-91b8-f8f01132ab37`); beta submission completed with external `IN_BETA_TESTING`.
- Public link enabled with no tester-count limit: https://testflight.apple.com/join/7c7b68t1. This verifies eligibility through the shared link, not a particular tester's installation.
- No physical strap/radio or actual background OS-restoration test was performed. The two opt-in background-upload tests remain skipped because they require an external receiver/background action.
