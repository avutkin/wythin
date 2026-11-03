# Continuous Polar Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every delivered Polar packet locally and on the server, derive metrics from sensor events at up to a two-second cadence in every app state, and show actual recording coverage.

**Architecture:** An append-only local packet journal sits immediately after Core Bluetooth delivery. A background URLSession uploads immutable segments to a lossless gzip archive on a separate mounted volume, indexed by an idempotent PostgreSQL manifest. Sensor arrivals drive scalar metric computation. The 24-hour chart shows the complete day, including missing intervals.

**Tech Stack:** Swift 5.9, Core Bluetooth, SwiftData, Foundation file I/O, FastAPI, asyncpg, PostgreSQL, XCTest, pytest.

**Spec:** `docs/superpowers/specs/2026-11-02-continuous-polar-capture-design.md`

## Global Constraints

- Preserve existing user identity and SwiftData history. Do not delete or rewrite prior rows.
- ECG and ACC use their delivered native device cadence and device timestamps. Derived metrics target roughly 2 s.
- The server may be offline; recording must continue locally and uploads must resume idempotently.
- Never infer continuity through an absent packet stream.
- All persisted raw bytes require access control and bounded network request size.

## Review Focus

- App suspended mid-file write: reopening must keep earlier complete records and discard only the incomplete tail. Test in Task 1.
- Duplicate upload after lost acknowledgement: server must store one packet. Test in Task 2.
- New recording after a long silent gap: no stale HRV window may be reused. Test in Task 3.
- Upload failure or bad HTTP status: cursor must stay put. Test in Task 4.
- Midnight and daylight-saving transition: coverage uses absolute instants, not naive local timestamps. Test in Task 5.

---

### Task 1: Durable raw packet journal — implemented

**Files:** `ios/Wythin/BLE/DataBuffer.swift`, `ios/Wythin/BLE/BLEService.swift`, `ios/WythinTests/BLETests.swift`.

**Interfaces:** Journal append accepts stream kind, exact notification bytes, receive time, and optional device timestamp. It seals immutable chunks with stable UUIDs; acknowledgement removes only a confirmed chunk.

- [x] Write tests for packet fidelity, restart recovery, and incomplete-tail handling.
- [x] Run focused XCTest and confirm failure.
- [x] Implement journal and connect it at the PMD and HR notification boundary.
- [x] Run focused XCTest and full iOS test scheme.
- [ ] Commit.

### Task 2: Idempotent raw ingest and export — implemented

**Files:** `server/db.py`, `server/main.py`, `server/routers/raw.py`, `server/routers/me.py`, `server/tests/test_raw.py`.

**Interfaces:** `POST /v1/raw/chunks/{id}` receives at most 1.5 MB and acknowledges its SHA-256 digest. `GET /v1/me/raw/chunks` and `GET /v1/me/raw/chunks/{id}` list and export the authenticated user's original bytes.

- [x] Write tests for byte round-trip, duplicate retry, malformed payload, and user scope.
- [x] Run focused pytest and confirm failure.
- [x] Implement schema, router, authorization, and export.
- [x] Run focused pytest and full server suite.
- [ ] Commit.

### Task 3: Sensor-driven metric scheduling — implemented

**Files:** Modify `ios/Wythin/App/AppEnvironment.swift`, `ios/Wythin/BLE/DataBuffer.swift`; test `ios/WythinTests/MetricsTests.swift` or a focused scheduler test file.

**Interfaces:** Fresh RR delivery schedules one metric compute if at least 2 s elapsed and no compute is active. The computation uses a snapshot after the delivered frame; connection gaps clear buffers. Background state does not change cadence.

- [x] Test that the trigger policy accepts fresh RR arrivals and rejects empty or stale frames without timer wakes.
- [x] Run focused XCTest and confirm failure.
- [x] Move persistence computation to event-driven scheduling with single-flight guard.
- [x] Run focused XCTest and full iOS test scheme.
- [ ] Commit.

### Task 4: Resumable raw uploads — implemented in code, field validation pending

**Files:** `ios/Wythin/Sync/APIClient.swift`, `ios/Wythin/App/AppEnvironment.swift`, `ios/Wythin/App/NudgeRouting.swift`, `ios/Wythin/UI/Settings/SettingsView.swift`.

**Interfaces:** The background URLSession uploads stable files, relaunches for completion, and verifies status, digest, and byte count before deleting local segments. Uploading is a separate opt-in and retries on launch, foreground, and new chunks.

- [ ] Write tests for failed status, lost reply, restart, and backlog drain.
- [ ] Run focused XCTest and confirm failure.
- [x] Implement uploader and independent retry triggers.
- [x] Run focused XCTest and full iOS test scheme.
- [ ] Commit.

### Task 5: Coverage and field validation — partial

**Files:** Modify `ios/Wythin/UI/Live/MetricsChartsView.swift`, `ios/Wythin/UI/Live/LiveView.swift`, `server/routers/admin.py`; tests for coverage calculations.

**Interfaces:** The 24-hour chart has a full calendar-day axis. Settings exposes pending raw chunks and errors. An independent server coverage endpoint and real-device overnight comparison remain to be implemented.

- [ ] Write coverage tests including DST and 5-minute gaps.
- [ ] Run focused tests and confirm failure.
- [ ] Implement coverage display and admin summary.
- [ ] Run full tests and build.
- [ ] Perform a real-device overnight background test, compare delivered raw packets to server acknowledgements, and document remaining iOS/Polar limits.
- [ ] Commit.
