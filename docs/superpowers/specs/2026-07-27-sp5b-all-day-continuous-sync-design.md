# SP5b — All-day continuous metric sync — Design

**Goal:** Continuously sync the app's live HRV metrics (all 13, incl. Inner Noise/PIP and the advanced set) to the server so Claude Code can answer questions like "what happened to my Inner Noise today?" — without the user logging anything — while keeping it opt-in and private.

**Status:** Approved decisions — **raw 2-second samples** (full fidelity); **opt-in** Settings toggle, off by default; **keep forever**; rollup-ready design.

**Depends on:** SP1 (tokens/auth), SP3 (`/mcp` + `resolve_bearer`), the existing app→server upload path (`X-User-ID` + shared key).

**Scope:** server (data layer + MCP tools) + app (opt-in toggle + uploader).

---

## Data model (server)

New table for continuous samples, separate from session-scoped `hrv_samples`:

```sql
CREATE TABLE IF NOT EXISTS metric_samples (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL,
    mean_bpm REAL, rmssd REAL, sdnn REAL, rsa_ms REAL, lf_hf REAL, stress REAL,
    coherence REAL, cbi REAL, breath_bpm REAL,
    rcmse REAL, pip REAL, dc REAL, dfa1 REAL, vti REAL,
    PRIMARY KEY (user_id, ts)
);
CREATE INDEX IF NOT EXISTS metric_samples_user_ts ON metric_samples(user_id, ts);
```

- `(user_id, ts)` PK makes uploads idempotent (re-sends are no-ops) and every query user-scoped.
- **Rollup-ready / "forever":** a plain indexed table handles the current scale for years. If volume ever demands it, we add a `metric_samples_rollup` (1-min aggregates) + prune raw, or migrate to monthly partitions — both are future ops changes, not schema-breaking. Not built now (YAGNI), but the shape doesn't block it.

## Upload endpoint (server)

`POST /v1/metrics` — gated by the shared `X-API-Key` and scoped by `X-User-ID` (same auth as `/sessions`/`/activities`; the app already sends both). Body:

```json
{ "samples": [ { "ts": "…Z", "mean_bpm": 62.0, "rmssd": 40.0, "pip": 33.0, "dc": 7.5, "dfa1": 1.0, "vti": 3.9, "rcmse": 2.1, "sdnn": …, "rsa_ms": …, "lf_hf": …, "stress": …, "coherence": …, "cbi": …, "breath_bpm": … }, … ] }
```

Handler resolves `user_id` via `get_or_create_user(x_user_id)`, then `executemany` an upsert `INSERT … ON CONFLICT (user_id, ts) DO NOTHING`. Returns `{ "stored": <count> }`. Caps batch size (e.g. 5,000/request) so the app chunks large backfills.

## Erase (server)

`DELETE /v1/me/data` — Bearer-authed (`current_user_id`), deletes the caller's `metric_samples` (and their `sessions` + `activities`), keeping the user row + tokens. Returns counts. Backs the Settings "Delete my cloud data" action.

## App side (iOS)

- **Opt-in toggle:** `@AppStorage("cloudSyncEnabled")` (default `false`), surfaced in the Settings **CLAUDE CODE ACCESS** section with a plain disclosure ("Continuously syncs your metrics to the server so Claude Code can read them"). Toggling on is the consent moment.
- **`MetricSyncService`:** when the toggle is on, periodically (every ~2 min while foregrounded, on app-background via `beginBackgroundTask`, and catch-up on launch):
  1. Query `HRVSample` where `timestamp > lastSyncedAt` (persisted `@AppStorage` ISO date), ordered, capped per batch.
  2. Map to the payload (the 13 metrics), `POST /v1/metrics`.
  3. On success, advance `lastSyncedAt` to the last uploaded `ts`. Idempotent server-side, so a crash mid-upload just re-sends harmlessly.
- **Cost:** raw 2 s gzips to ~80–100 KB per worn-hour (~<1 MB/day heavy use), batched over the already-active session — negligible battery/data. No new always-on background mode.
- **Off by default:** if the toggle is off, `MetricSyncService` never runs and nothing leaves the device.

## MCP tools (server) — aggregate views over raw storage

Raw 2 s is stored, but tools return **aggregated** views (a day is ~43k rows — never dumped raw). Added to `server/mcp_server.py`, token-scoped like the others:

1. **`get_day_summary(date)`** → per-metric `{avg, min, max, first, last, n}` for that day (single SQL aggregate row). Directly answers "Inner Noise today."
2. **`get_metric_trend(metric, since, until, buckets=60)`** → a downsampled series: the time range split into ~`buckets` equal windows, each with the metric's avg (SQL `width_bucket`/`date_bin`). ~60 points for a clean trend.
3. **`get_metric_stats(metric, since, until)`** → avg/min/max/n over an arbitrary range (for comparisons like "this week vs last").

All resolve `user_id` from the token; no user_id argument; `metric` validated against the known column set (prevents SQL-column injection); ranges parsed with `_parse_dt`.

## Build decomposition (one plan, SDD tasks)

1. **Server data layer** — `metric_samples` table (db.py), `POST /v1/metrics` router, `DELETE /v1/me/data`; tests (upsert idempotency, scoping, erase).
2. **MCP tools** — `get_day_summary` / `get_metric_trend` / `get_metric_stats` over `metric_samples`; helper + scoping tests; column-allowlist test.
3. **App uploader + toggle** — `MetricSyncService`, `APIClient.uploadMetrics`, the Settings toggle + "Delete my cloud data" button; build-verified.

Order: Task 1 → (Task 2 + Task 3 depend on it). Server tasks use the `.venv313` + local Postgres harness; the app task uses `xcodebuild`.

## Privacy summary

Opt-in (off by default), plain disclosure at the toggle, explicit erase path, user-scoped everywhere, TLS in transit; **enable encryption-at-rest on the Hetzner Postgres** as an ops step (documented, not code). Identity remains device-UUID + shared key (Apple Sign-In is the future hardening).

## Out of scope

- Rollup/partitioning (deferred until scale needs it).
- Encryption-at-rest is an ops/config step, tracked separately from this code.
- Apple Sign-In identity hardening.
