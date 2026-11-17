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
- [x] Integrate, deploy server/schema/backfill, verify real read-only data and MCP. Publish the matching app update using tools/ship.sh and verify TestFlight state.

## Evidence / decisions

Baseline main: 77cf87d (build 148). Root cause: metric_samples/HRVSample have no per-tick Stress Balance; MCP aliases stress_balance to lf_hf. Activities already save before/during/afterStress. Existing worktree is clean and reused for this follow-up. Test DB: local PostgreSQL on 127.0.0.1:55439, wythin_stress_test; production is never a test target.

Initial server test reproduced a missing stress_balance key in export. All 24 new server cases then passed; the complete suite on a fresh isolated database passed **200 tests**. An intermediate repeated run failed test_user_metrics_series and test_user_metrics_resolution_follows_the_data because their fixed device IDs accumulated prior-run rows (4 vs 2 and 6400 vs 3200); a fresh database, matching CI, resolved that without changing those tests. The expected metric-count assertion is now 15 and verifies lower-is-calmer direction.

Four iOS tests first failed to compile on the absent snapshot and wire fields, then 24 focused tests and 1761 full tests passed. Independent review found the pre-existing session camel-case wire contract would prevent the newly added snapshot from reaching /sessions. Added failing encoded-request assertions and mapped SessionPayload/SamplePayload keys explicitly. Also observed a stored-snapshot nudge assertion fail and delegated that reader to LiveMetric. Final full iOS run passed all **1761 tests**, zero failures, at 15:54 PST; server full suite passed **200 tests**, zero failures. git diff --check passed. Existing legacy /sessions retry duplication is outside this change; continuous uploads retain idempotency.

Read-only production audit before deployment: 1,166,806 continuous samples; 1,135,251 have recoverable positive finite RMSSD. Kt Kt has 357,480 samples, 348,921 recoverable from RMSSD. Production uses a clean /opt/pulsar checkout on prod at e1c9d46, service pulsar-api; deploy only this server diff to preserve its unrelated dashboard customizations.

## Server release and production verification

Integrated code as `c7a4ebc`. GitHub Actions run 43983342736 passed its Python test job; automatic deployment could not start because DEPLOY_HOST/SSH-key secrets are unset (same existing configuration issue as the prior run). Applied the exact reviewed server diff to clean production and committed it there as `e0a967e`, preserving unrelated prod-branch changes. Database backup before changes: `/root/wythin-pre-stress-c7a4ebc.dump` on the server.

Deployment incident: a restrictive umask intended for the backup also affected git apply, making rewritten source files unreadable by the pulsar service account. This caused HTTP 502 from roughly 23:56 to 23:59 UTC on November 16. Restored source modes to 0644 and ownership to pulsar, confirmed import as the service account, restarted, and verified both workers' startup and public/private health 200. Future deployments must confine the backup umask to a subshell and check imports as the service account before restart.

Backfill filled **1,135,251** historical Stress Balance values. Kt Kt: **348,921** non-null snapshots among 357,480 samples, zero recoverable missing values. A real authenticated GET /v1/metrics/export returned HTTP 200 and the saved value 43.65583038330078 for RMSSD 51.625789642333984; LF/HF remained separately null. Production MCP helper stats returned metric=stress_balance, n=348921, avg=49.591; trend values stayed within 0–100. The connected Wythin tool also resolves stress_balance as its own key (its authenticated account had no rows in the requested date range).

TestFlight publishing uses only tools/ship.sh. Its additional full iOS suite passed; build **149**, version 1.1, commit `1de8501`, uploaded successfully. Release notes saved in English and Russian. After Apple processing, build 149 became VALID with export compliance set; Beta App Review is APPROVED and both Internal and the existing External Testers group include 149 with IN_BETA_TESTING state. No tester roster or public-link setting was changed.

Apple upload ID `ad2092ab-7cc3-4721-ae39-c7cd74486f3d` reports PROCESSING with empty errors/warnings as of 00:07 UTC November 17; the upload is accepted, not a failed export. Global post-backfill audit: 1,135,251 stored stress values, zero recoverable missing, zero outside 0–100. The isolated local PostgreSQL test instance has been stopped.

Final independent verification: Apple build `ad2092ab-7cc3-4721-ae39-c7cd74486f3d` is VALID, review APPROVED, Internal and External Testers both include 149 and both testing states are IN_BETA_TESTING. Public API health returns HTTP 200/status ok. Code is unchanged since the full 1761 iOS / 200 server tests and the additional successful ship.sh full iOS suite.
