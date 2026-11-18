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
- [ ] Add failing endpoint/validation/replay/order/isolation/retention/deletion/stage tests against a new isolated local database.
- [ ] Implement exact wire spec, ingestion transaction and bounded cleanup, admin stages and panel.
- [ ] Run targeted then full server suite; report outputs and any pre-existing failures.
Interfaces: POST events -> accepted_ids; GET admin latest per installation and bounded event timeline, field names per spec.

### Task 2: iOS wire models, durable outbox and independent background transport
Owner: transport worker. Files: existing root-provided BLE/RecordingDiagnosticEvent.swift, new Sync/RecordingDiagnosticOutbox.swift, Sync/RecordingDiagnosticSync.swift, tests/RecordingDiagnosticTransportTests.swift. Root owns pbxproj registration and APIClient extension.
- [ ] Write failing persistence/replay/corruption/capacity/age/scoping tests and transport tests for exact ACK, retry without metrics, restore, cancellation, stale completion.
- [ ] Use the root-provided Codable model and encoder()/decoder() helpers; optional nested fields have nil defaults, counters0 defaults. Root owns model changes.
- [ ] Expose @MainActor RecordingDiagnosticSync(client:APIClient,userID:String, defaults:UserDefaults=.standard, directory:URL?=nil, configuration:URLSessionConfiguration?=nil, now:()->Date=Date.init).
- [ ] Expose start(), submit(event:RecordingDiagnosticEvent), setEnabled(Bool), handleBackgroundEvents(completionHandler:), installationID, launchID, launchSequence, nextSequence(), droppedReports. Session static sessionIdentifier, active, pendingBackgroundCompletionHandler follow MetricSyncService pattern.
- [ ] Root supplies APIClient.recordingDiagnosticUploadRequest(userID:String)->URLRequest. Retain injectable default URLSession for tests; use URLProtocol only for default-session tests, real listener for background smoke.
- [ ] Run focused tests once root registers files; return code and verification evidence.

### Task 3: Capture integration and consent
Owner: root. Files: new App/RecordingDiagnosticReporter.swift and tests/RecordingDiagnosticReporterTests.swift; modify BLE/DataBuffer.swift, BLE/BLEService.swift, App/AppEnvironment.swift, Sync/APIClient.swift, App/NudgeRouting.swift, UI/Settings/SettingsView.swift, App/WythinApp.swift, project.pbxproj.
- [ ] Test cadence without metrics, lifecycle snapshots, computed-vs-durable-save counters, RR/ECG independence, sanitized errors, disabled cloud sync.
- [ ] Add non-writing audit snapshot, safe BLE metadata + state-change signals, typed metric upload metadata and outcome callback; reporter reads these and tracks compute/save stages.
- [ ] Wire launch/timer/BLE/lifecycle/save/error events and background completion. Update cloud-sync disclosure and cancellation paths.
- [ ] Verify full iOS suite and compile Release through sanctioned ship pipeline only after integration to main.

### Task 4: Review, staged deployment and TestFlight
- [ ] Fresh independent review of full diff; fix important findings with focused verification.
- [ ] Full server/iOS suites green, diff check; merge/push latest main while preserving other work.
- [ ] Verify production service/deploy reality (known host uses /opt/pulsar; workflow paths may be historical), deploy additive support safely and confirm endpoint/auth/retention/deletion without injecting KT health data.
- [ ] Run tools/ship.sh testflight, finish ASC processing/compliance/review/External Testers under prior explicit release authorization.
- [ ] Report exact verified build, server availability, and remaining real-device/background limits.


### Task 5: Timely delivery during Bluetooth execution (before Task4 release)
Owner: transport integration worker. Files: shared new finite immediate file transport in Sync plus tests, MetricSyncService in APIClient.swift, RecordingDiagnosticSync.swift and focused tests/project registration. Follow Task3 deletion pause/fence interface.
- [ ] Reproduce KT failure with a held system-background upload and new locally saved samples; default-session lane must deliver while host is backgrounded/executing without opening UI.
- [ ] Add an independent immediate file-upload attempt for metrics and diagnostics while execution is available. Keep existing native background-session immutable queue as fallback for suspension/termination. One immediate transfer per uploader, finite20-second timeout and finite UIKit allowance,30-second minimum spacing, exponential failure cooldown30→3600s. Respect persisted batch retry deadlines; monotonic spacing is independent of wall-clock changes. No timer claims to wake a suspended process.
- [ ] Share exact immutable bytes and existing ACK validation. Durable first valid receipt wins, cancel counterpart after receipt persistence, fence late completions/consent/account/delete scope, keep pending on invalid ACK/failure. Separate delegates prevent cross-session taskIdentifier collisions. Immediate failure leaves system task alive and does not double-increment durable batch retry; side-lane bounded cooldown is separate.
- [ ] Active lanes are independent: metric queue blockage/network failure cannot suppress diagnostic upload. Stop/cancel active allowances and timers on consent off/deletion. Resume only fresh diagnostic snapshots after deletion.
- [ ] Correct last_attempt_at to actual network start evidence (didSendBodyData/transaction metrics), never completion or creation of a future scheduled retry. Test absent before network starts, present during in-flight transfer, unchanged by finish.
- [ ] Meaningful tests: native task held + immediate exactACK, immediate failure + native success, race bothACK orders, stale callbacks, malformedACK, cooldown/backoff/clockchange, consent/delete cancellation, metrics stalled + diagnostics delivered. Include real loopback HTTP and opt-in host-background harness. Full suite after integration; physical24h/lockedPolar validation remains a stated limitation.
