# Complete Data Capture — Design

**Date:** 2026-07-28
**Status:** Design approved; pending implementation plans (one per block)
**Scope:** Close every gap between what the app knows and what reaches the server and Claude Code — onboarding, live metrics at full granularity, activities, the three never-synced features, and app-usage telemetry.

**Supersedes / absorbs:**
- `2026-07-27-sp5a-activity-mcp-tools-design.md` (becomes block C)
- `ios/Wythin/docs/superpowers/specs/2026-07-28-usage-telemetry-design.md` (becomes block E, extended with per-screen tracking and an MCP tool)
- `docs/BACKLOG.md` line "SP5a — activity MCP tools"

---

## Goal

Every piece of data the app collects is (a) stored server-side and (b) readable by Claude Code through the MCP server. The two halves are one deliverable: data that lands in Postgres but has no MCP tool is invisible, and a tool over data that never syncs returns nothing.

## Audit — starting state

**Complete today:**
- **Onboarding.** All 7 collected fields (phone, email, age range, gender, goals, practices, devices) sync via `POST /v1/profile` → `profiles`, exposed as `get_profile` and folded into `whoami`. No gap.
- **Tick persistence on device.** Every ~2 s tick is written to `HRVSample` (`AppEnvironment.swift:420`), in foreground *and* background, into an auto-created session. The local store is complete; the loss is in transit.

**Gaps:**

| # | Gap | Evidence |
|---|---|---|
| 1 | `MetricSamplePayload` sends 14 of `HRVSample`'s 26 metric fields | `APIClient.swift:170` |
| 2 | Activities sync but have **no** MCP tools — Claude cannot read any activity | `mcp_server.py` (no activity tools) |
| 3 | `ActivityLog.insightText` never uploaded; no server column | `ActivityUploader.swift`, `db.py` |
| 4 | `DailyAnchor` / Day Potential, `TrainSession`, `ResonanceResult` never leave the device | no uploader references them |
| 5 | Usage telemetry 0% implemented (spec only, committed 95eddaf) | no table, endpoint, or instrumentation |
| 6 | Session-scoped `hrv_samples` carries 10 fields (no `dfa1`/`rcmse`/`pip`/`dc`/`vti`) | `db.py`, `SamplePayload` |

Dropped in gap 1: `rsa_idx`, `ie_ratio`, `ials`, `motion`, `signal_quality`, `rr_invalid_rate`, `rr_corrected_rate`, `ecg_quality_tier`, `ulf_power`, `vlf_power`, `lf_power`, `hf_power` — i.e. all four spectral bands, motion, and all four data-quality fields. The quality fields matter most: without them Claude cannot distinguish a real reading from a strap-off artifact.

## Decisions

| Question | Decision |
|----------|----------|
| Store-only, expose-only, or both? | **Both** — every block ships storage *and* an MCP tool. |
| Usage tracking depth | **App-level + per-screen** — opens, foreground duration, ECG wear, plus per-tab dwell time. Not discrete interaction events. |
| Historical data | **One-time backfill** — re-upload local history so existing rows gain the new fields, rather than leaving the past permanently thinner than the present. |
| Session samples | Read from `metric_samples` by time range rather than widening `hrv_samples` — full fidelity, no duplicate storage. |
| Day Potential | Store the **computed score as the user saw it**, alongside the raw anchors — Claude reports the number rather than re-deriving it. |
| Raw ECG | **Out of scope** — stays backlog SP6. |

---

## Block A — Full-fidelity metric samples (26/26)

**Schema.** Add to `metric_samples`: `rsa_idx REAL, ie_ratio REAL, ials REAL, motion REAL, signal_quality REAL, rr_invalid_rate REAL, rr_corrected_rate REAL, ecg_quality_tier INT, ulf_power REAL, vlf_power REAL, lf_power REAL, hf_power REAL`. Added to `SCHEMA_SQL` as idempotent `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements (the table already exists in production).

**Upsert semantics.** `POST /v1/metrics` flips from `ON CONFLICT (user_id, ts) DO NOTHING` to `DO UPDATE SET` on every metric column. Without this, backfilled rows cannot be enriched in place — the conflict would silently discard them.

**App.** `MetricSamplePayload` and the `MetricSyncService` mapping extend to all 26 fields.

**Backfill drain rate.** The normal uploader does 2,000 rows per 120 s tick-driven pass. At 43,200 ticks/day that is ~21 hours of foreground time per month of history — unusable. Backfill therefore runs as a distinct mode:

1. `@AppStorage("metricsSyncSchemaVersion")` — when below the current version, clear `metricsLastSyncedAt` once and set a `backfilling` flag.
2. While backfilling, batches of 5,000 (the server cap) loop back-to-back with no 120 s wait, until a fetch returns fewer rows than the batch size (~260 requests per month of history).
3. Clear the flag, stamp the version, resume normal cadence.

Backfill respects `cloudSyncEnabled` and yields between batches so it never blocks the main actor.

**MCP.** Extend `_METRIC_COLS` with the 12 new columns so `get_day_summary` / `get_metric_trend` / `get_metric_stats` cover all 26. Add aliases to `_METRIC_ALIASES`: `stillness`→`motion`, `quality`→`signal_quality`, `breathing_ratio`→`ie_ratio`, `fragmentation`→`ials`.

**Acceptance:** a tick's 26 on-device fields round-trip to `get_day_summary`; re-uploading an already-stored `ts` with new fields updates the row; a month of history backfills without a foreground-time stall.

## Block B — Session samples without duplicate storage

`get_session_samples` currently reads `hrv_samples` (10 fields). Rather than widen that table to 26 and store every tick twice, it reads `metric_samples` over the owning session's `[started_at, ended_at)` range: full fidelity, no new columns, one source of truth.

- Ownership check is unchanged (`SELECT 1 FROM sessions WHERE id = $1 AND user_id = $2`), then the range query is scoped by `user_id` as well.
- `hrv_samples` is retained read-only for rows already stored; the app stops populating it (`SessionPayload.samples` becomes empty or the field is dropped from the upload).
- Sessions remain the index — `list_sessions` / `get_session` are unchanged.

**Acceptance:** `get_session_samples` returns 26-field rows for a session recorded after block A; a pre-existing session still resolves (from `metric_samples` where coverage exists).

## Block C — Activities complete and reachable

**Schema.** Add `insight_text TEXT` to `activities`.

**App.** `ActivityUploadPayload` gains `insight_text`, mapped from `ActivityLog.insightText`. Because the insight is generated asynchronously after an activity ends, the uploader must re-upload an activity when its insight later arrives — the endpoint already upserts on `client_activity_id`, so this is a matter of clearing the synced flag when `insightText` is set.

**MCP.** Implement SP5a as specified in `2026-07-27-sp5a-activity-mcp-tools-design.md`:
- `list_activities(limit=50, since=None, until=None, activity_type=None)` — newest first, limit capped at 200.
- `get_activity(activity_id)` — the full before/during/after grid for all 11 metrics, plus `insight_text`.

Both resolve `user_id` via `_auth(ctx)`, take no user_id argument, and filter every query by `user_id`; `get_activity` validates the UUID and verifies ownership.

**Acceptance:** an activity logged in the app is listable and retrievable through MCP with its full metric grid and its AI insight.

## Block D — Day Potential, Train, Resonance

Three features that have never left the device.

**Schema.**

```sql
CREATE TABLE IF NOT EXISTS daily_anchors (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day         DATE NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL,
    duration_sec DOUBLE PRECISION,
    hour        DOUBLE PRECISION,
    ln_rmssd    REAL, dc REAL, resting_hr REAL, pip REAL, dfa1 REAL, breath_bpm REAL,
    late        BOOLEAN, motion_known BOOLEAN, confidence TEXT,
    PRIMARY KEY (user_id, day)
);

CREATE TABLE IF NOT EXISTS day_potential (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day         DATE NOT NULL,
    score       INT, band TEXT, confidence TEXT, late BOOLEAN,
    components  JSONB,        -- {metric: {z, level}}
    modifiers   JSONB,        -- {name: value}
    baseline_anchors INT, baseline_target INT, baseline_sufficient BOOLEAN,
    streak_current INT, streak_best INT, grace_used BOOLEAN,
    PRIMARY KEY (user_id, day)
);

CREATE TABLE IF NOT EXISTS train_sessions (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id   TEXT PRIMARY KEY,
    started_at  TIMESTAMPTZ NOT NULL, ended_at TIMESTAMPTZ,
    baseline_hr REAL, baseline_rmssd REAL,
    set_count   INT, avg_sns_index REAL, avg_pns_index REAL,
    avg_recovery_min REAL, recovery_mins JSONB
);

CREATE TABLE IF NOT EXISTS resonance_results (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id   TEXT PRIMARY KEY,   -- ResonanceResult.id
    session_id  TEXT,               -- ResonanceResult.sessionID
    recorded_at TIMESTAMPTZ NOT NULL,
    best_bpm       REAL,
    best_coherence REAL,
    best_rsa_ms    REAL
);
```

Storing `day_potential` as well as `daily_anchors` is deliberate: the score is what the user actually saw, and re-deriving it server-side from anchors would risk drifting from the on-device computation as the scoring code evolves. The `components`/`modifiers` JSONB mirrors `DayPotentialPayload`, which already carries exactly this shape for the insight endpoint.

**Ingest.** `POST /v1/anchors`, `/v1/day-potential`, `/v1/train`, `/v1/resonance` — shared-key gated, `X-User-ID` scoped, upsert on the primary key. All four are low volume (≤1 row/day or a handful total), so backfill is simply "upload everything not yet marked synced" on the normal sync pass; no special drain mode.

**App.** Extend `MetricSyncService` (or a sibling service) to flush these alongside metrics, gated by the same `cloudSyncEnabled` toggle. Anchors and day-potential rows are keyed by day, so re-uploading is harmless.

**MCP.** `get_day_potential(date)`, `list_day_potential(since, until)`, `list_train_sessions(limit, since, until)`, `list_resonance_results(limit)`. `get_day_potential` returns the score plus the anchor that produced it, joined on `(user_id, day)`.

**Acceptance:** a day with an anchor produces a `get_day_potential` result matching the score shown in the app, including streak state and component breakdown.

## Block E — Usage telemetry (app-level + per-screen)

**Schema.**

```sql
CREATE TABLE IF NOT EXISTS usage_events (
    id          BIGSERIAL PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type  TEXT NOT NULL,          -- 'foreground' | 'ecg_recording' | 'screen'
    ts          TIMESTAMPTZ NOT NULL,   -- when the interval STARTED
    duration_ms BIGINT,
    detail      TEXT,                   -- screen name for 'screen'; NULL otherwise
    client_event_id TEXT UNIQUE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS usage_events_user_ts ON usage_events(user_id, ts);
```

**iOS `UsageTracker`.**
- `foreground` — observes `scenePhase`; records start on `.active`, emits `{ts, duration_ms}` on leaving `.active`. The app already tracks `isInForeground` (`AppEnvironment.swift:59`, `WythinApp.swift:52`).
- `ecg_recording` — hooks the `BLEService` connect/disconnect lifecycle; one event per wear session.
- `screen` — a `.trackScreen("Live")` view modifier on each tab root, recording dwell via `onAppear`/`onDisappear`, with `detail` = screen name (Live, Activities, Train, History, Settings).
- Events buffer to a small on-disk JSON file (not SwiftData — avoids the schema-migration risk called out in `ClientProfile.swift`), batch-POST to `/v1/usage` on foreground and after connection, marked synced on success and retried on failure. Each carries a client-generated UUID.
- Gated by `cloudSyncEnabled`.
- v1 may lose the in-progress foreground interval on force-quit. Accepted.

**Ingest.** `POST /v1/usage` — shared-key gated, `X-User-ID` scoped, bulk insert `ON CONFLICT (client_event_id) DO NOTHING`, batch size capped.

**Admin.** `GET /admin/users/{id}/usage?days=N` → per-day `[{day, opens, active_min, ecg_recordings, ecg_min, screens: {name: min}}]` plus window averages; per-user `avg_opens_day` / `avg_active_min_day` / `avg_ecg_day` added to `/admin/stats`. Dashboard surfaces these as overview columns and a per-user Usage panel.

**MCP.** `get_usage_summary(since, until)` → per-day opens, active minutes, ECG recordings and minutes, and per-screen minutes — so Claude sees engagement, not just the admin dashboard.

**Acceptance:** opens, active minutes, ECG wear and per-screen dwell appear in `usage_events`; re-upload is idempotent; `get_usage_summary` returns correct per-day totals.

## Block F — Cross-cutting

**Erase completeness.** `DELETE /v1/me/data` deletes 4 tables today. It must be extended to `daily_anchors`, `day_potential`, `train_sessions`, `resonance_results`, and `usage_events`. Without this, "delete my cloud data" silently leaves data behind the moment block D or E ships — a correctness bug, not a nicety. This ships with whichever of D/E lands first.

**Consent.** All new sync is gated by the existing `cloudSyncEnabled` toggle. The Settings disclosure is updated to name usage analytics explicitly alongside metrics — usage tracking is a category users reasonably expect to be told about.

**Scoping invariant.** Every new MCP tool resolves `user_id` from the Bearer token via `_auth(ctx)`, accepts no user_id argument, and filters every query by `user_id` — matching the existing tools. Every new ingest endpoint scopes by `X-User-ID` through `get_or_create_user`.

## Sequencing

| Order | Block | Depends on |
|-------|-------|------------|
| 1 | A — full-fidelity metrics | — |
| 2 | C — activities | — (parallel with A) |
| 3 | E — usage telemetry | — (parallel with A); ships F's erase fix |
| 4 | B — session samples from `metric_samples` | A |
| 5 | D — day potential / train / resonance | — (largest new surface, last) |

Each block is server → app → MCP, and each gets its own implementation plan. Server work uses the `.venv313` + local Postgres harness; app work is `xcodebuild`-verified.

## Out of scope

- **Raw 130 Hz ECG** — backlog SP6. ~2 MB/day typical, needs chunked `bytea` storage and its own consent decision.
- **Discrete interaction events** (buttons tapped, insight requested, onboarding step completions) — per-screen dwell is the agreed depth.
- **Encryption at rest** — runbook exists at `server/deploy/ENCRYPTION_AT_REST.md`; ops task, more pressing as this spec multiplies stored personal data.
- **Apple Sign-In** — identity hardening, tracked separately.
