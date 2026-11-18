# Automatic recording diagnostics

## Intent and authorization
The user requested automatic diagnostics for all users so support can distinguish Bluetooth receipt, local recording and cloud delivery without manual export. KT is the motivating case, not a feature flag. Screenshot evidence confirms build 156, strap worn except a 30-minute break, fresh ECG/ACC/RR arrivals at 14:43 Sydney, nearly empty history, and a red sync status. Fresh server samples appeared only around a foreground opening. Do not label a stage healthy based on the toolbar pulse or a diagnostic upload alone.

## Approach
Use structured periodic snapshots and state-change snapshots in an independent durable background uploader. This is the implementation choice under the user's request. Uploading the existing free-form log export would expose unnecessary strings and make reliable classification difficult; attaching diagnostics to metric batches would hide them behind the failing stage. Existing cloudSyncEnabled gates collection and delivery; update its explanatory copy. No raw signals, metric values, names, sensor identifiers, credentials, localized errors or arbitrary metadata.

## Wire contract (schema 1)
POST /v1/recording-diagnostics uses the existing X-API-Key gate and X-User-ID device-account mapping. This existing authentication is not strong per-account device attestation. Body: {events: [event]}, 1..50 events, max 256 KiB. Reply: {accepted_ids: [event UUID strings]}; the exact set must match the immutable batch before deletion. Replays count as accepted; conflicting event identities return 409. JSON dates are timezone-aware ISO 8601.

All object keys below are snake_case and unknown fields are forbidden. Integers are nonnegative <= 2^53-1 unless narrower below; ages are finite 0..315360000 seconds; optional fields may be absent/null.

Event required:
- schema_version: exactly 1; event_id, installation_id, launch_id: UUID
- launch_sequence, sequence: positive integer
- observed_at: aware datetime; uptime_seconds: finite nonnegative
- reason: launch | heartbeat | lifecycle | state | save_error | memory_warning | termination
- app_version, app_build, os_version: 1..32 technical characters [A-Za-z0-9._ -]
- phase: foreground | background | inactive | unknown
- sensor, recording, delivery: objects below
- dropped_reports: nonnegative integer (reports removed by the local bound, never metrics)

Sensor required: central_state (unknown/resetting/unsupported/unauthorized/powered_off/powered_on), connection_state (idle/scanning/connecting/connected/disconnected/standby/unauthorized/unsupported), intended (bool), rr_live/ecg_live/acc_live (bool), generation (integer).
Sensor optional: connection_age_seconds, last_rr_at, last_ecg_at, last_acc_at, sensor_contact (bool), hr_packets/ecg_packets/acc_packets/rr_intervals/valid_rr_intervals/invalid_packets (integers), error_domain (core_bluetooth/pmd/cocoa/posix/other), error_code (signed 32-bit), error_at (date).

Recording required: computed_count, saved_count, failed_save_count (integers).
Recording optional: last_computed_at, last_computed_sample_at, last_saved_at, last_saved_sample_at (dates), computed_age_seconds, saved_age_seconds, rr_active_age_seconds, save_error_domain (cocoa/sqlite/other), save_error_code (signed 32-bit).
Counters and monotonic ages are from the current launch. rr_active_age_seconds measures continuous intended, connected RR activity from the first valid RR in the current generation; reset after a >4-second RR gap, reconnect, standby or pause. Track packet uptime so a suspended timer does not conceal a gap. last_saved_at means a successful durable save, not a displayed tick.

Delivery required: state (unknown/idle/uploading/retrying/storage_blocked), queued_batches, in_flight, maximum_attempts (integers).
Delivery optional: pending_samples (integer; nil before a store scan), oldest_queued_at, last_attempt_at, last_ack_at, last_ack_sample_at (dates), last_http_status (100..599), last_error_code (signed 32-bit).
Delivery describes METRIC uploads. Diagnostic upload success never changes those fields.

## iOS design
Use existing isolated worktree. New focused files: BLE/RecordingDiagnosticEvent.swift (wire types), Sync/RecordingDiagnosticOutbox.swift (disk state), Sync/RecordingDiagnosticSync.swift (transport), App/RecordingDiagnosticReporter.swift (cadence/snapshot coordinator). Existing RecordingDiagnostics.swift manual export remains available.
- Persist installation UUID and increasing launch number in the scoped outbox. Generate a new launch UUID for each process and increasing event sequence. Queue namespace includes userID and server URL.
- Report at launch, foreground/background transitions, and meaningful connection/save-error changes; heartbeat every 60 seconds while intended recording or foreground. A 15-second coalescing bound applies to repeated state changes; lifecycle/launch/error transitions remain durable promptly. A fallback timer must not depend on RR or metric ticks. BLE callbacks can also request a due heartbeat.
- Snapshot the in-memory CaptureAuditLog counters under its lock, not by uploading its file. Record compute success and persistence success/failure separately in AppEnvironment. Read actual BLE liveness, not latestTick. Add numeric BLE error metadata and typed metric delivery metadata.
- Outbox: atomic protected files, excluded from backup, max 2048 pending reports and 48h queued age; never evict an in-flight immutable batch. Count report drops. Corrupt individual reports must not block all future diagnostics.
- Background URLSession file upload, independent of the metric queue; one immutable batch of <=50 reports at a time, newest reports first so offline backlog cannot hide current state. Survives process restart, reconciles task IDs, retries 30s exponential to 1h using earliestBeginDate. Wrong/partial/malformed acknowledgements preserve the batch. Terminal HTTP 400/409/413/422 drops that immutable batch, counts all its reports in dropped_reports, and advances to newer reports; do not retain rejected payloads in an unbounded quarantine. Authentication errors, 404 (server rollout), 408/429, 5xx and transport errors retry with the bounded backoff. New data is not required for retry.
- Turning cloud sync off cancels known and restored transfers and clears unsent diagnostic reports. Already accepted server reports remain subject to retention or Delete my cloud data. Re-enable starts with a fresh report. A stale callback cannot remove a newer batch or cross an account/server namespace.
- UIApplicationDelegate routes this background session's completion only after durable delegate handling. No promise of heartbeats while iOS suspends/force-quits the process. Startup reports plus persisted prior snapshots provide retrospective evidence.
- Pure injected clock/session/storage seams for tests; no test-only switches in product flows.

## Server and support view
Add recording_diagnostics table with JSONB payload plus identity/order/observed_at/received_at columns. PK(user_id,event_id); unique(user_id,installation_id,launch_sequence,sequence). Exact duplicate preserves original receipt and payload; changed replay conflicts transactionally. Latest is ordered per installation by launch_sequence,sequence; never let a delayed older batch replace the newest snapshot. Different installations are shown separately.
Keep 14 days from received_at and at most 25,000 reports per user. Purge on ingestion and periodic server maintenance/startup so inactive users also expire. Include diagnostics in DELETE /v1/me/data.
GET /admin/users/{user_id}/recording-diagnostics: per-installation latest snapshot/stages/freshness, max 100 recent events, server metric last-sample and receipt timestamps for cross-check. Unknown user 404; read uses existing admin key gate. Never change Last strap semantics.
Freshness: an observed report older than 180s, received report older than 180s, or phone time >120s in future means current stage status UNKNOWN (historical report remains visible). No report means not available/older client, not sensor failure.
Evaluate three stages independently:
- Sensor: paused when !intended; standby explicit; disconnected/BT off explicit; connected startup (<60s) warming; otherwise missing RR is rr_stalled, RR live with ECG absent is ecg_stalled, both live receiving. Missing observations unknown.
- Local: current save error is save_error; intended connected startup with no save is warming; RR live with rr_active_age_seconds >60s and no save ever, or a saved_age >60s, is processing_stalled if compute is absent/stale (>60s), else save_stalled; before 60s of continuous RR with no save it is warming; saved_age <=60s recording. If upstream is paused/stalled, do not mislabel absent downstream records as a storage fault.
- Delivery: storage_blocked/retrying explicit; pending samples with oldest batch >180s awaiting_upload; in-flight or recent pending uploading; empty known backlog up_to_date; unknown counters unknown.
The dashboard user detail shows observed and received time, build, three stage states, and recent events. Escape values using existing helpers, clear state when switching users, guard late responses by user ID. No credentials or payload in the public HTML shell.

## Verification and delivery
Test missing/stale/clock-skew reports, RR-only and ECG-only stalls, save errors, metric upload failures with diagnostic success, interrupted/out-of-order uploads, duplicate/conflicting IDs, account/installation isolation, local/server bounds, consent cancellation across relaunch, deletion and restart. Use a real localhost HTTP listener for a background URLSession smoke test when supported; simulator tests do not establish locked-iPhone or 24h Polar reliability.
Run relevant red/green tests, full iOS and server suites, independent code review. Deploy additive server support, verify authenticated reads, then ship via tools/ship.sh TestFlight under the ongoing release authorization. No production sample injection into KT's account. Update KT diagnosis only from real reports after she installs the new build.


## Evidence-based delivery amendment (2026-11-17)
KT manual diagnostics plus server receipts show continuous Bluetooth and successful local saves during a30minute background cloud gap;675 samples arrived together after foreground. Apple makes background-created URLSession background transfers discretionary even when isDiscretionary=false (https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary). Apps with a valid background execution mode can use a default URLSession during execution (https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).
Both metric and diagnostic uploaders therefore use a bounded immediate default-session lane while the process runs, alongside the existing durable system-session fallback. This does not add a keepalive or imply an iOS wake guarantee. The lanes share immutable request content and exact ACK criteria, not credentials on disk, and the first durable valid receipt wins. Side-lane failures retain the fallback and use a separate bounded cooldown; persisted batch retry deadlines are always respected. Consent, deletion and scope cancellation fence both lanes. Actual network-start timestamps replace completion timestamps for metric attempt diagnostics.
