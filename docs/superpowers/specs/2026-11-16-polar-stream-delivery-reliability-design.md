# Polar recording and delivery reliability

The user approved implementing the priority findings from the same-iPhone multi-app investigation for all Wythin users and preparing a new TestFlight build. There is no account-specific behavior. The investigation's private server evidence remains outside the release commit.

## Required behavior

- A stalled ECG stream must recover while RR and motion remain healthy. RR liveness uses the same accepted interval range as the data buffer. Recovery runs from incoming Bluetooth events and permitted lifecycle execution, without requiring the Live screen.
- PMD commands are serialized with response handling, bounded retry, session/characteristic guards and selective stream restart. Standby, manual stop and iOS-owned pending reconnect retain ownership. Healthy sessions are not periodically disconnected.
- Queued frames, resets and computations carry a recording generation. A pre-gap result cannot become a new saved measurement. Freshness/order use monotonic receipt time; wall time remains the capture timestamp. Selectively resumed PMD waveforms cannot bridge an outage.
- A successful local metric save creates durable pending membership. Bounded immutable file batches are delivered by background URLSession independently of future RR ticks. Startup reconciles system tasks, including suspended tasks; receipts persist before local acknowledgement and file removal. Failures retain data with bounded retry. Existing timestamp cursors are migrated without hiding new rows after equal/backward timestamps.
- Every cloud-consent UI entry point cancels known uploads immediately on opt-out, including an in-flight profile request. Unsent data stays local. Re-enabling resumes the backlog.
- The Settings diagnostic export combines bounded capture, BLE/delivery events and build/lifecycle/stream/upload metadata, including missing-section or write failures. It excludes raw waveforms and credentials.

## Chosen approach and alternatives

Extend the existing CoreBluetooth service and SwiftData records, with a small durable metric file queue. This preserves the current protocol and backend. Repeated full reconnects would disrupt healthy RR and cannot force another app to release the shared physical link. A new SDK migration, accessory setup flow or sensor-internal RR reserve would expand the change beyond the approved priority repairs; those remain separate investigations.

The backend's existing `(user_id, ts)` idempotency remains unchanged. Two local rows with an identical serialized timestamp can still map to one server row; delivery membership prevents either row from being silently omitted by a moving client timestamp cursor.

## Verification and limits

Use failing regression tests before fixes, a full iOS simulator suite, a fresh code review and an opt-in real background URLSession smoke test with a loopback receiver and externally backgrounded host app. The latter proves software transport behavior, not physical H10 contention or OS termination restoration. Real multi-app/locked-iPhone and 72-hour/7-day tests require accessible equipment and must not be represented as completed without evidence.

The platform controls suspended execution and background transfer timing; user force-quit and unavailable hardware remain distinct states. See [Apple background transfer guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) and [Bluetooth restoration rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules).

## Release

Full tests must pass before integrating the scoped change into current origin/main. The repository's `tools/ship.sh testflight` is the sole archive/upload path. Verify processing and external testing availability before claiming delivery.
