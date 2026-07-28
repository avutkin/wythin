# Usage Telemetry — Design

**Date:** 2026-07-28
**Status:** Design (brainstormed); pending implementation plan
**Scope:** Instrument the iOS app to report how often it's opened, how long it's actively used, and how often the ECG strap is worn — store those events on the backend and surface per-user engagement in the admin dashboard. This is sub-project 1 ("usage telemetry") of the admin-analytics outline (`2026-07-26-admin-analytics-dashboard-design.md`).

## Goal

Answer, per user and per day: how many times they opened the app, how much time they spent with it active, and how many ECG-recording (strap wear) sessions they did (and for how long) — visible in the admin dashboard.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| What is an "app open"? | **Every foreground** — each time the app becomes active (fresh launch *and* return from background/lock). |
| Active time per day | **Sum of foreground durations** (time the app is in the foreground). |
| What is one "ECG recording"? | **Each strap connect → disconnect** (a wear session). Also yields total ECG minutes/day. |
| Force-quit mid-foreground | v1: the in-progress foreground duration may be lost on force-kill. Acceptable; optionally close it out on next launch later. |

## Metrics delivered

Per user, per day (and averaged across the selected window):
- **Opens/day** — count of foreground events.
- **Active minutes/day** — sum of foreground-event durations.
- **ECG recordings/day** — count of ecg_recording events.
- **ECG minutes/day** — sum of ecg_recording durations.

## Data model

One table, both event kinds share it (mirrors the existing `metric_samples`/`activities` sync style):

```sql
CREATE TABLE IF NOT EXISTS usage_events (
    id          BIGSERIAL PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type  TEXT NOT NULL,          -- 'foreground' | 'ecg_recording'
    ts          TIMESTAMPTZ NOT NULL,   -- when the interval STARTED
    duration_ms BIGINT,                 -- interval length (ms); NULL only if unknown
    client_event_id TEXT UNIQUE,        -- iOS-generated UUID → idempotent upload
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS usage_events_user_ts ON usage_events(user_id, ts);
```

- `foreground` — `ts` = when the app became active; `duration_ms` = how long it stayed foreground.
- `ecg_recording` — `ts` = strap connected; `duration_ms` = wear length until disconnect.
- `client_event_id` makes re-uploads idempotent (`ON CONFLICT DO NOTHING`), like the other uploaders.

## iOS instrumentation

- **Foreground events:** observe `scenePhase`. On `.active`, record a start timestamp; on leaving `.active` (`.background`/`.inactive`), emit a `foreground` event `{ts: start, duration_ms}`. (The app already tracks `isInForeground` in `AppEnvironment`.)
- **ECG-recording events:** hook the BLE connection lifecycle (already in `BLEService`). On connect + first stream, record a start; on disconnect (or stream stop), emit an `ecg_recording` event `{ts: start, duration_ms}`.
- **Buffer + upload:** persist pending events locally (small SwiftData model or a JSON file), batch-POST to `/v1/usage` on foreground and after connection, mark synced on success, retry on failure — the same resilient pattern as `MetricSyncService`/`ActivityUploader`. Respect the existing `cloudSyncEnabled` toggle.
- Each event gets a client-generated UUID (`client_event_id`).

## Backend

- **Migration:** add `usage_events` to `server/db.py` `SCHEMA_SQL` (created idempotently on startup).
- **Model:** `UsageEvent` / `UsageUpload` (batch) in `server/models.py`.
- **Ingest:** `POST /v1/usage` in a new `server/routers/usage.py` — `X-User-ID` header, gated by `X-API-Key` (same as `/v1/metrics`); `get_or_create_user`; bulk insert with `ON CONFLICT (client_event_id) DO NOTHING`. Cap batch size.
- **Admin aggregation:** `GET /admin/users/{id}/usage?days=N` → per-day series `[{day, opens, active_min, ecg_recordings, ecg_min}]` plus window averages. Extend `/admin/stats` per-user rows with `avg_opens_day`, `avg_active_min_day`, `avg_ecg_day` for the overview.

## Dashboard

- **Overview:** add columns (or a small KPI) for **Opens/day**, **Active min/day**, **ECG/day** per user — real engagement signal (unlike the session-based KPIs, which are ~0 for this app's usage).
- **User detail:** a "Usage" panel — opens/day bar chart, active-minutes trend, ECG recordings + minutes — reusing the existing inline-SVG chart helpers.

## Success criteria

- The app emits and uploads `foreground` and `ecg_recording` events; they appear in `usage_events`.
- `POST /v1/usage` is idempotent (re-upload doesn't duplicate) and gated by the API key.
- `/admin/users/{id}/usage` returns correct per-day opens / active-min / ECG counts.
- The dashboard shows opens/day, active min/day, and ECG recordings/day per user, averaged over the window.

## Out of scope

- Screen-level / per-feature analytics (which tabs used) — only app-level open/active + ECG wear.
- Precise foreground accounting across force-kills (v1 may drop the final in-progress interval).
- Backfill of past usage (no historical events exist; data accrues from the instrumented build forward).

## Sequencing

Independent of the dashboard-chart work. Natural order: (1) backend table + ingest + admin aggregation, (2) iOS instrumentation + uploader, (3) dashboard surfacing. Backend first lets the app start sending as soon as it ships.
