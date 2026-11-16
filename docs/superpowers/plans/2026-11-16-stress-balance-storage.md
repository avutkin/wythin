# Stress Balance storage implementation plan

> Execute inline using superpowers:executing-plans, with a whole-change independent review.

**Goal:** Persist the app's Stress Balance and expose it consistently in exports and Wythin MCP.
**Architecture:** Optional sample snapshot; separate SQL column and wire key; backwards-compatible derivation for older data; missing-only batched backfill.
**Tech stack:** Swift/SwiftData, Python/FastAPI, PostgreSQL, XCTest, pytest.
**Spec:** ../specs/2026-11-16-stress-balance-storage-design.md

## Constraints and review focus

Preserve raw LF/HF and the existing metric formula. Never infer zero for missing evidence. Preserve known snapshots on retries/restores. Aggregate the per-sample dial, not a dial from average RMSSD. Keep caller scoping. Do not touch other worktrees; shipping uses tools/ship.sh.

## Tasks

- [x] Server regression tests fail: explicit and legacy upload/export, stats/trend/day/session MCP, CSV, invalid values, missing-only backfill and idempotent re-upload.
- [x] Add SQL column/function, ingest compatibility, exports, connector field/description, session summary and dashboard series mapping. Add bounded backfill script. Pass focused and full server suites against isolated PostgreSQL.
- [x] iOS regression tests fail: stored snapshot precedence, capture/save/reload, payload and cloud restore, old optional fields. Add optional model/history fields, shared extraction and wire mapping; use stored value across charts/activity/rollups. Pass focused and full XCTest suite.
- [x] Independent review, fix regressions, final verification and commit.
- [ ] Integrate, deploy server/schema/backfill, verify real read-only data and MCP. Publish the matching app update using tools/ship.sh and verify TestFlight state.

## Evidence / decisions

Baseline main: 77cf87d (build 148). Root cause: metric_samples/HRVSample have no per-tick Stress Balance; MCP aliases stress_balance to lf_hf. Activities already save before/during/afterStress. Existing worktree is clean and reused for this follow-up. Test DB: local PostgreSQL on 127.0.0.1:55439, wythin_stress_test; production is never a test target.

Initial server test reproduced a missing stress_balance key in export. All 24 new server cases then passed; the complete suite on a fresh isolated database passed **200 tests**. An intermediate repeated run failed test_user_metrics_series and test_user_metrics_resolution_follows_the_data because their fixed device IDs accumulated prior-run rows (4 vs 2 and 6400 vs 3200); a fresh database, matching CI, resolved that without changing those tests. The expected metric-count assertion is now 15 and verifies lower-is-calmer direction.

Four iOS tests first failed to compile on the absent snapshot and wire fields, then 24 focused tests and 1761 full tests passed. Independent review found the pre-existing session camel-case wire contract would prevent the newly added snapshot from reaching /sessions. Added failing encoded-request assertions and mapped SessionPayload/SamplePayload keys explicitly. Also observed a stored-snapshot nudge assertion fail and delegated that reader to LiveMetric. Final full iOS run passed all **1761 tests**, zero failures, at 15:54 PST; server full suite passed **200 tests**, zero failures. git diff --check passed. Existing legacy /sessions retry duplication is outside this change; continuous uploads retain idempotency.

Read-only production audit before deployment: 1,166,806 continuous samples; 1,135,251 have recoverable positive finite RMSSD. Kt Kt has 357,480 samples, 348,921 recoverable from RMSSD. Production uses a clean /opt/pulsar checkout on prod at e1c9d46, service pulsar-api; deploy only this server diff to preserve its unrelated dashboard customizations.
