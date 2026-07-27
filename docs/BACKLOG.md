# Wythin — Backlog

Open items after the personal-data-API / MCP arc (see `docs/superpowers/specs` & `plans`). Not yet started.

## SP6 — Send complete ECG data (backlog)
Sync the raw 130 Hz ECG waveform to the server (currently ECG is a live `ecgSubject` stream in `BLEService.swift`, consumed for the waveform + quality tier, then **discarded** — not persisted).
- **Complexity: moderate–large** (~1.5–2× SP5b), same architecture + one net-new piece.
- **Rate/volume:** 130 Hz ≈ 468k samples/hour; int16+gzip ≈ 400–550 KB/hour → ~2 MB/day typical, ~10–12 MB/day 24/7 (7–15× the metric sync). Per-sample = billions of rows/year → **must store as compressed chunks** (`ecg_chunks(user_id, start_ts, sample_rate, samples bytea)`, ~10 s segments = ~1,500–3,000 rows/day).
- **New work vs SP5b:** on-device ECG capture/buffering (net-new — it isn't stored today); chunk/compress/upload service; server chunk table + endpoint; bounded segment/export tool (`get_ecg_segment(from,to,max_seconds)` — Claude can't ingest raw 130 Hz).
- **Decisions:** wifi-only/throttled upload; shorter retention or rollup (ECG is bulky); **opt-in** (medical-adjacent, stronger consent than the default-on metric sync). Confirm first: does ECG stream continuously while connected, or only on the Live screen?

## Smaller open items
- **SP5a — activity MCP tools** (`list_activities` / `get_activity`): activities are already synced server-side; just needs the two tools (mirror the session tools). Small.
- **Encryption at rest** — runbook ready at `server/deploy/ENCRYPTION_AT_REST.md`; needs a maintenance window (no app perf impact). More relevant now that metric sync is default-on.
- **Apple Sign-In** — stronger identity than the current device-UUID + shared-key model.
- **Redundant `metric_samples` index** (`db.py`) — `(user_id, ts)` index duplicates the PK; drop it. Trivial.
- Deferred SP5b Minors: `stored` count = submitted (not inserted); `_day_bounds` uses `fromisoformat` directly (a full timestamp shifts the day window); delete-my-data token transiently shown in the token list until refresh.
