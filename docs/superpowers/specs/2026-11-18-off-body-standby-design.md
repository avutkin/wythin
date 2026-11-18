# Off-body standby correction

The reported screenshot shows explicit off-body contact while ECG noise continues and a cached quality result remains GOOD. The regression is the unconditional ECG-packet liveness veto in StandbyPolicy; raw electrical samples do not establish that a person is wearing the strap.

## Approach and scope

Keep the existing pause-in-place behavior: stop ECG/ACC notifications and commands after sustained off-body evidence, retaining the HR connection for automatic resume. A full disconnect would reconnect to the still-advertising removed strap and could lose background resume. A contact-only stop would regress overnight recording when dry electrodes report false contact; fresh RR or a plausible HR beacon therefore remains protective. ECG packet arrival alone cannot veto a fresh explicit off-body decision. Contact observations expire four seconds after their accepted HR notification, using monotonic receipt time. An expired contact bit becomes unknown for automated entry, diagnostics and presentation; it cannot stop a worn strap while RR recovery repairs a stalled HR subscription.

Use the existing 5-second strong-evidence and 45-second borderline dwell, expressed in a small monotonic policy shared by notification and foreground-poll paths. Reset dwell on connection generation changes, loss of the connected state or contradictory wear evidence. No new timer wake guarantee. Preserve HR/RR recovery when contact is unknown or true and ECG is still flowing.

The Bluetooth sheet must replace cached GOOD/clean values with an off-body/paused state when contact is false and there is no recent RR or plausible heartbeat, or when already in standby. Hide old waveform traces in that state. Unknown contact must remain unknown: raw ECG packets cannot label it on skin. After resume clear the old displayed trace before accepting new samples. Do not alter historical metrics, auto-upload, raw-archive rollout or standby resume thresholds.

Implementation choices above are ours within the user's explicit request to fix removal/resume; no separate design approval is needed for this correction.

## Verification and release

Reproduce the original veto with a failing test. Exercise continuing ECG/no RR, false contact with real RR/HR, unknown contact with an RR stall, dwell resets, standby PMD suppression and resume. Verify that cached good quality is masked and prior traces clear on state change. Run focused tests then the full signed iOS suite and independent final review. Ship the correction through tools/ship.sh under the ongoing update authorization. Distinguish simulated callback/background behavior from a physical H10 removal test, which is not available here.

Primary reference: Polar's SDK exposes sensor-contact and contact-supported flags independently of ECG data: https://github.com/polarofficial/polar-ble-sdk/blob/master/sources/iOS/ios-communications/Sources/iOSCommunications/ble/api/model/gatt/client/BleHrClient.swift.

Released as externally approved **TestFlight 158**. See [verification and release record](../plans/2026-11-18-off-body-standby.md#released--testflight-158).
