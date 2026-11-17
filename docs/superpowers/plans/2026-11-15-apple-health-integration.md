# Apple Health Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Automatically import authorized HealthKit workouts and context into Wythin, with durable local synchronization, source-aware analysis, and a separately authenticated cloud API.

**Architecture:** A HealthKit adapter returns portable value types. A serialized local repository persists changes, cursors and an outbox, then projects workouts into ActivityLog. The server independently stores installation-owned records and revisioned analysis; the legacy uploader never sends Health records.

**Tech Stack:** Swift/SwiftUI/SwiftData/HealthKit/Charts, FastAPI/Pydantic/asyncpg/PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-11-15-apple-health-integration-design.md` (approved by user 2026-11-15).

## Global Constraints

- Work only in `codex/apple-health-integration`; no deployment, device install, or modification of other worktrees.
- Before `[start-300s,start)`, during `[start,end)`, after `[end,end+600s]`; no fabricated Polar samples or SDNN→RMSSD conversion.
- Read-only HealthKit; explicit Health cloud consent; single writer; every read/delete scoped by independent 256-bit installation credential.
- Up to 200 changes / 2 MiB per batch. One ordered outbound stream, stable retry IDs, atomic acknowledgement, epoch guards.
- Preserve all available workout history, source UUIDs, unknown activity types, long durations, paused duration, and condensed series.
- `HKDeletedObject` is a deletion; an empty/unauthorized query is not.
- No production Health transfer through legacy `/activities`, PAT, admin dashboard or MCP.

## Review Focus

- A sample arrives after its workout is already imported: invalidate old analysis regardless of age (Tasks 2/3).
- Purge while offline or an upload is in flight: old epoch must never resurrect data (Tasks 1/3).
- App terminates between a local commit and network ACK: retry must preserve exactly one logical change (Tasks 1/3).
- Reinstall or restore with unacknowledged local edits: preserve dirty/tombstoned local state and saved credential (Task 3).
- Sparse or condensed measurements near window boundaries: no double counting or false coverage/HRR (Tasks 2/4).

## Task 1: Independent Health API and PostgreSQL persistence

**Files:** Create `server/health/{models,auth,store,router}.py`, `server/health/__init__.py`, `server/tests/test_health.py`, `server/tests/test_health_postgres.py`; modify `server/main.py`, `server/db.py`.

**Interfaces:** JSON endpoints from spec at `/v1/health`. Enrollment returns `installation_id, credential`; connection POST takes `stream_id, cloud_consent, consent_version` and returns `connection_id, connection_epoch, expected_sequence`. Batch envelope matches spec. Change discriminant `operation`; payload keys `workout`, `sample`, `analysis`, `annotation`, `series`. Response includes acknowledged sequence, revision, canonical workout mappings. GET activities returns `items, next_cursor`; each item includes `external_id, activity_id, workout, analysis, annotation, deleted, server_revision`. Sample/detail data remain owner scoped.

- [x] Write failure-first tests for enrollment without caller-chosen owner; missing/legacy credentials; batch replay/different-payload conflict; order/epoch; validation; user isolation; deletion and staging; purge.
- [x] Run focused tests and observe failure before implementation.
- [x] Implement typed Pydantic payloads, SQL schema, mandatory auth dependency, transactions and operation ledger. One stream with row lock; canonical hashes; bounded data. Export concrete wire fixtures for iOS integration.
- [x] Exercise real PostgreSQL in an isolated temporary cluster: rollback on failed batch, concurrent retry, owner isolation, cursor pagination, staged series visibility and terminal tombstones.
- [x] Run all server tests; preserve baseline failures separately; commit task changes after integration review.

## Task 2: HealthKit adapter and source models

**Files:** Create `ios/Wythin/Health/HealthTypes.swift`, `HealthKitSource.swift`, `HealthWorkoutMapping.swift`; tests `ios/WythinTests/HealthAnalysisTests.swift`, `HealthMappingTests.swift`.

**Interfaces:** `HealthSource` has `available`, `requestAuthorization() async throws`, `workoutPage(anchor: Data?) async throws -> HealthWorkoutPage`, `samplePage(metric: HealthMetric, anchor: Data?) async throws -> HealthSamplePage`, `samples(metric: HealthMetric, start: Date, end: Date) async throws -> [HealthSample]`, `startObserving(onChange: @escaping @Sendable () async -> Void)`, `stopObserving()`.

DTOs are Codable/Sendable values with UUID identifiers, Date intervals, source metadata, metric units, workout events, and quantity-series point/interval representation. Page results carry `nextAnchor`, additions, deleted parent UUIDs, and `hasMore`. Adapter uses bounded queries (200 workouts, 500 samples) and series enumeration; test fakes implement the same protocol.

- [x] Write pure mapping tests: running neutral label, unknown type preserved, pauses/long duration retained.
- [x] Implement HealthKit queries, source conversion and secure anchor coding; request only the documented read types, register observer/background delivery early and always complete callbacks.
- [x] Read series containers correctly, retain parent UUID for deletion, query interval overlap for pre/post context, normalize units.
- [x] Compile adapter against installed iOS SDK and test pure models; explicitly record physical-device-only checks.

## Task 3: Durable local repository, import coordinator and cloud client

**Files:** Create `ios/Wythin/Health/HealthRepository.swift`, `HealthSyncCoordinator.swift`, `HealthCloudClient.swift`, `HealthCredentialStore.swift`; add tests `HealthRepositoryTests.swift`, `HealthSyncTests.swift`.

**Interfaces:** Local repository owns durable Health-specific SwiftData records separate from Polar schema; import methods atomically save data/anchor/outbox. Coordinator provides `connect()`, `synchronize()`, `disconnect()`, `setCloudEnabled(_:)`, `deleteImportedData()` and observable status. Cloud client implements Task 1 contract. Credential uses Keychain AfterFirstUnlockThisDeviceOnly.

- [x] Failure-first tests for replay, old workouts, update/delete, persisted anchors/outbox, crash retry, local dirty restore, purge/offline and consent gating.
- [x] Implement local durable repository, separate Health schema/container, serialization, bounded read queries and ordered outbox. Keep partial series hidden until committed.
- [x] Implement coordinator: workouts first, context fetch, incremental sample streams, invalidate overlapping windows, bounded background work and resumable history. New workouts re-read their context even if earlier delta samples were discarded.
- [x] Implement HTTPS client, Keychain enrollment, consent/epoch enforcement, backoff and failure reporting. Upload snapshots/annotations without using legacy endpoints; drain queued purge before other work.
- [x] Validate source-aware projection into ActivityLog; preserve existing manual records and use explicit optional origin/external ID fields. Suppress legacy upload/backfill overwrites for imported records.
- [x] Test persistence across reopen and network failure; no user health data needed.

## Task 4: Source-aware analysis and product integration

**Files:** Create `ios/Wythin/Health/HealthAnalysis.swift`, `HealthSettingsView.swift`, `HealthActivityDetailView.swift`; modify `App/WythinApp.swift`, `App/AppEnvironment.swift`, `UI/Settings/SettingsView.swift`, `UI/Activities/ActivitiesView.swift`, `Models/ActivityLog.swift`, `Sync/ActivityUploader.swift`, `ios/Wythin/Info.plist`, `ios/Wythin.xcodeproj/project.pbxproj`; add `ios/Wythin/Wythin.entitlements`.

**Interfaces:** `HealthAnalysis.compute(workout:samples:now:)` returns Codable revisioned per-source/window statistics and conservative HRR. UI displays this projection and existing real Polar context separately. Health service starts observers at launch and resumes on foreground, never requires opening Settings to sync.

- [x] Failure-first window tests for exact boundaries, nil data, sparse HRR, SDNN independence, overlapping sources, late samples, coalesced intervals.
- [x] Implement pure analysis; never draw graph segments over unobserved gaps; retain observed counts and method.
- [x] Add connect/consent/status/sync/disconnect/delete UI in existing theme; imported workout routing in journal and source badge.
- [x] Add HealthKit entitlements/descriptions, register every new source/test in pbxproj, wire startup and scene changes, and include Health purge in general account/data deletion before clearing credential.
- [x] Run focused iOS tests on a simulator, then full WythinTests; build generic iOS simulator app. Verify migration preserves existing ActivityLog fields and imported records are excluded from legacy upload.

## Task 5: Review and delivery

- [x] Review spec coverage and actual diff; test synthetic wire fixture round-trip across Swift/Python.
- [x] Run independent final code review of auth, persistence, deletes, UI consent and tests; fix substantive findings with regression tests.
- [x] Save API usage and device-verification instructions in repository docs. State simulator checks versus physical HealthKit checks honestly.
- [x] Commit local branch; report artifacts and tests. Deployment/merge/TestFlight require a separate concrete action, not implied by the specification approval.

## Execution record

User approved implementation; no second approval requested for routine task decomposition. Backend and HealthKit adapter have disjoint files and can be delegated under `dispatching-parallel-agents`; root owns Swift models, persistence, analysis, UI and pbxproj. Agents must not edit shared files without coordination.

## Verification outcome — 2026-11-16

Full WythinTests: 1754 passed, no failures/skips; full server suite on isolated PostgreSQL: 201 passed. Exact Swift repository JSON ingested/replayed/restored by PostgreSQL. Previous persisted ActivityLog schema migration passed. Independent review findings fixed and rechecked; device-only HealthKit, background delivery, signing and Keychain acceptance remain documented in docs/apple-health-integration.md. Existing theme reused. Manual links intentionally persist device-local IDs. General cloud deletion preserves local Health history. Source and cloud snapshots use distinct provenance, with monotonic local purge generation in addition to server epochs. Work kept in its separate branch, without merge, push, deployment or device install.
