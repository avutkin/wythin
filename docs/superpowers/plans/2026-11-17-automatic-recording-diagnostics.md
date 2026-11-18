# Automatic Recording Diagnostics Implementation Plan

> For agentic workers: use superpowers:subagent-driven-development for independent server/transport tasks and native integration, followed by whole-change review.

**Goal:** Automatically show where recording stopped: sensor, processing/storage, or metric delivery.
**Architecture:** Strict technical snapshot contract, independent durable background outbox, per-installation server history and conservative stage classification.
**Tech Stack:** Swift/SwiftData/CoreBluetooth/URLSession; Python FastAPI/Pydantic/PostgreSQL; existing admin HTML.
**Spec:** docs/superpowers/specs/2026-11-17-automatic-recording-diagnostics-design.md

## Global Constraints
No raw signals, physiological values, names, identifiers of sensors, credentials, arbitrary dictionaries or free-form error logs. Respect cloudSyncEnabled. Missing/stale diagnostic heartbeat is UNKNOWN. Server retention14days,25,000/user; client2048reports/48h;50reports/request. All identifiers scoped to account and installation. Existing Last strap meanings unchanged.

## Review Focus
- A fresh diagnostic upload carrying old snapshots must not imply current sensor health.
- Metric-upload failure must not prevent diagnostics and diagnostic success must not acknowledge metrics.
- Disabled consent plus restored background tasks must send nothing and not resurrect cleared records.
- Reinstall/second installation and delayed prior launch must not replace another installation's newest state.
- Main-actor/processing stall and missing ECG with live RR must remain distinguishable from Bluetooth disconnection.

### Task 1: Server contract, storage, classification, admin access
Owner: server worker. Files: new server/routers/recording_diagnostics.py and server/tests/test_recording_diagnostics.py; modify server/db.py, main.py, routers/me.py, routers/admin.py, templates/dashboard.html.
- [x] Add failing endpoint/validation/replay/order/isolation/retention/deletion/stage tests against a new isolated local database.
- [x] Implement exact wire spec, ingestion transaction and bounded cleanup, admin stages and panel.
- [x] Run targeted then full server suite; report outputs and any pre-existing failures.
Interfaces: POST events -> accepted_ids; GET admin latest per installation and bounded event timeline, field names per spec.

### Task 2: iOS wire models, durable outbox and independent background transport
Owner: transport worker. Files: existing root-provided BLE/RecordingDiagnosticEvent.swift, new Sync/RecordingDiagnosticOutbox.swift, Sync/RecordingDiagnosticSync.swift, tests/RecordingDiagnosticTransportTests.swift. Root owns pbxproj registration and APIClient extension.
- [x] Write failing persistence/replay/corruption/capacity/age/scoping tests and transport tests for exact ACK, retry without metrics, restore, cancellation, stale completion.
- [x] Use the root-provided Codable model and encoder()/decoder() helpers; optional nested fields have nil defaults, counters0 defaults. Root owns model changes.
- [x] Expose @MainActor RecordingDiagnosticSync(client:APIClient,userID:String, defaults:UserDefaults=.standard, directory:URL?=nil, configuration:URLSessionConfiguration?=nil, now:()->Date=Date.init).
- [x] Expose start(), submit(event:RecordingDiagnosticEvent), setEnabled(Bool), handleBackgroundEvents(completionHandler:), installationID, launchID, launchSequence, nextSequence(), droppedReports. Session static sessionIdentifier, active, pendingBackgroundCompletionHandler follow MetricSyncService pattern.
- [x] Root supplies APIClient.recordingDiagnosticUploadRequest(userID:String)->URLRequest. Retain injectable default URLSession for tests; use URLProtocol only for default-session tests, real listener for background smoke.
- [x] Run focused tests once root registers files; return code and verification evidence.

### Task 3: Capture integration and consent
Owner: root. Files: new App/RecordingDiagnosticReporter.swift and tests/RecordingDiagnosticReporterTests.swift; modify BLE/DataBuffer.swift, BLE/BLEService.swift, App/AppEnvironment.swift, Sync/APIClient.swift, App/NudgeRouting.swift, UI/Settings/SettingsView.swift, App/WythinApp.swift, project.pbxproj.
- [x] Test cadence without metrics, lifecycle snapshots, computed-vs-durable-save counters, RR/ECG independence, sanitized errors, disabled cloud sync.
- [x] Add non-writing audit snapshot, safe BLE metadata + state-change signals, typed metric upload metadata and outcome callback; reporter reads these and tracks compute/save stages.
- [x] Wire launch/timer/BLE/lifecycle/save/error events and background completion. Update cloud-sync disclosure and cancellation paths.
- [x] Verify full iOS suite and compile Release through sanctioned ship pipeline only after integration to main.

### Task 4: Review, staged deployment and TestFlight
- [x] Fresh independent review of full diff; fix important findings with focused verification.
- [x] Full server/iOS suites green, diff check; merge/push latest main while preserving other work.
- [x] Verify production service/deploy reality (known host uses /opt/pulsar; workflow paths may be historical), deploy additive support safely and confirm endpoint/auth/retention/deletion without injecting KT health data.
- [x] Run tools/ship.sh testflight, finish ASC processing/compliance/review/External Testers under prior explicit release authorization.
- [x] Report exact verified build, server availability, and remaining real-device/background limits.


### Task 5: Timely delivery during Bluetooth execution (before Task4 release)
Owner: transport integration worker. Files: shared new finite immediate file transport in Sync plus tests, MetricSyncService in APIClient.swift, RecordingDiagnosticSync.swift and focused tests/project registration. Follow Task3 deletion pause/fence interface.
- [x] Reproduce KT failure with a held system-background upload and new locally saved samples; default-session lane must deliver while host is backgrounded/executing without opening UI.
- [x] Add an independent immediate file-upload attempt for metrics and diagnostics while execution is available. Keep existing native background-session immutable queue as fallback for suspension/termination. One immediate transfer per uploader, finite20-second timeout and finite UIKit allowance,30-second minimum spacing, exponential failure cooldown30→3600s. Respect persisted batch retry deadlines; monotonic spacing is independent of wall-clock changes. No timer claims to wake a suspended process.
- [x] Share exact immutable bytes and existing ACK validation. Durable first valid receipt wins, cancel counterpart after receipt persistence, fence late completions/consent/account/delete scope, keep pending on invalid ACK/failure. Separate delegates prevent cross-session taskIdentifier collisions. Immediate failure leaves system task alive and does not double-increment durable batch retry; side-lane bounded cooldown is separate.
- [x] Active lanes are independent: metric queue blockage/network failure cannot suppress diagnostic upload. Stop/cancel active allowances and timers on consent off/deletion. Resume only fresh diagnostic snapshots after deletion.
- [x] Correct last_attempt_at to actual network start evidence (didSendBodyData/transaction metrics), never completion or creation of a future scheduled retry. Test absent before network starts, present during in-flight transfer, unchanged by finish.
- [x] Meaningful tests: native task held + immediate exactACK, immediate failure + native success, race bothACK orders, stale callbacks, malformedACK, cooldown/backoff/clockchange, consent/delete cancellation, metrics stalled + diagnostics delivered. Include real loopback HTTP and opt-in host-background harness. Full suite after integration; physical24h/lockedPolar validation remains a stated limitation.


## Delivery record — build 157 (2026-11-17 America/Los_Angeles)

Released source: `a0e77c8` on `origin/main`; feature and review fixes through `b897242`. The sanctioned `tools/ship.sh testflight` pipeline completed once, with archive/upload success. App Store Connect confirms build **157** (`17b46dd2-2da8-41a1-a3ec-b85d1466d348`) is VALID, beta review APPROVED, and both internal and external states IN_BETA_TESTING. Membership in **External Testers** was verified against the expanded group build list (the default ten-build relationship omits newer entries). English and Russian testing notes were updated; automatic tester notifications are enabled. Public invitation: https://testflight.apple.com/join/7c7b68t1.

The supplied manual diagnostics identified a delivery delay during the approximately 30-minute background interval: Bluetooth packet counters and successful local saves continued, with no save failures, but 675 samples reached the server together after foregrounding. Historical connection errors in the persistent log use a pre-151 format and must not be assigned to build 156 from the export header alone. The raw log and personal identifiers were not added to the repository.

Both metric and diagnostic uploaders now attempt delivery while the process has execution time, with durable system background transfers retained as fallback. Automatic technical reports separately describe sensor reception, local computation/persistence and metric delivery. Reports respect cloud-sync consent and contain no raw ECG/RR or physiological values. No diagnostic absence is treated as proof of Bluetooth failure.

### Verification

- Full signed iOS suite after the final client change: **1,942 tests, 2 opt-in skips, 0 failures**. The sanctioned release pipeline independently passed the same full suite.
- Actual simulator-background HTTP smoke passed: the sample was saved after the host entered the background; the native system upload was deliberately held; the ordinary save notification and coalescing path delivered an exact acknowledgement and marked the sample uploaded while the host remained backgrounded. The app was not reopened. This establishes the tested execution path, not 24-hour physical iPhone/Polar reliability.
- Main server suite: **245 passed**. Exact production projection: **212 Python tests and 2 dashboard tests passed**. Twenty actual Swift-encoded diagnostic reports validated against the server model.
- Independent final review and its single scoped fix review approved the changes, including consent withdrawal across accounts/endpoints, restoration receipt ordering, background allowance lifetime and required diagnostic authentication.
- Physical locked-iPhone/H10 testing over 24 hours remains unverified. KT's next real reports after installing 157 are needed to establish her device's outcome; no synthetic samples were written to her account.

### Server deployment and remaining access decision

The active service is `pulsar-api` in `/opt/pulsar`. A tested additive projection preserving unrelated production behavior was deployed as **`5ed00fb`**. Health returned 200; the new diagnostic admin route returned 401 without the key and 200 with the app's key. At release time KT had no automatic reports yet, as expected from build 156.

Both new diagnostic routes require authentication even when the legacy optional global gate is disabled. Production has `RECORDING_DIAGNOSTICS_API_KEY` configured. The pre-existing global `API_KEY` gate remains disabled: changing access to all existing app/admin routes is awaiting the user's answer to the explicit approval question. Existing clients without the key could be affected by that broader change.

GitHub run https://github.com/avutkin/wythin/actions/runs/44245323483 passed Python tests but its legacy deployment job failed before connecting to the server because deployment secrets were empty. Its deployment path also differs from the active service. This is not a green deployment workflow; the reviewed manual deployment above succeeded independently. No unrelated workflow/secrets changes were made.

### Implementation decisions and costs

These preserve all rulings from the temporary execution ledger, in order:

1. Add `rr_active_age_seconds`, resetting after a gap over four seconds, reconnect, standby or pause. This distinguishes an initial processing stall from warm-up. Cost: one optional wire field; an incorrect grace boundary could misclassify an early stall.
2. Drop and count diagnostic batches rejected with terminal HTTP 400/409/413/422; retry transient, authentication, rollout and malformed-acknowledgement failures. This prevents a rejected report blocking all later reports. Cost: rejected diagnostic history is lost; metrics are unaffected.
3. Proceed under the user's existing implementation and release authorization without another design approval. Cost if that scope were misunderstood: an unintended release; the user explicitly requested this release and the work was reviewed before deployment.
4. Keep one canonical wire model owned with the reporter while the transport consumes it. This avoids concurrent schema drift. No intended product cost; incorrect coordination would require integration rework.
5. At the exceptional limit of more than 25,000 installations for one account, retain the installations with the most recently received latest snapshots. Otherwise preserve each installation's latest snapshot before filling history. Cost: older installations may disappear at that bound or under normal retention.
6. Add bounded immediate upload attempts for metrics and diagnostics alongside immutable system background transfers, based on the observed delay and Apple's scheduling behavior. Cost: potentially duplicate network delivery, controlled by exact acknowledgement, idempotency and cancellation fences; no new wake-up guarantee.
7. Implement truthful `last_attempt_at` timing together with the immediate delivery change, using actual network-start evidence rather than scheduling/completion. The deferred finding was resolved before release. Cost if omitted would have been misleading delivery diagnostics; it is covered by regression tests.
8. Require a configured key on the two new diagnostic routes, with a dedicated fallback key while broader existing-route protection awaits approval. Cost: an additional configuration dependency; missing configuration fails closed. This does not resolve the pre-existing global access gap.
