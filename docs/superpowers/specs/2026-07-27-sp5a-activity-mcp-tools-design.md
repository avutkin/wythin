# SP5a — MCP tools over synced activities — Design

**Goal:** Expose the user's logged activities (practices) through the MCP server so Claude Code can analyze them — the full before/during/after metric grid + impact score per activity — scoped to only the user's own data.

**Status:** Approved — start SP5 with activity MCP tools (activities are already synced server-side; no new sync needed).

**Depends on:** SP1 (tokens), SP3 (the `/mcp` server + `resolve_bearer` + the session-tool pattern), and the existing `activities` table + `/activities` upload (already in production).

**Scope:** Server only — add two tools to `server/mcp_server.py`. No app change, no schema change, no new sync.

---

## Data available (already synced)

The `activities` table holds, per activity: `id` (server UUID), `activity_type`, `activity_subtype`, `custom_name`, `started_at`, `ended_at`, `is_manual`, `impact_score`, `notes`, and a **before/during/after grid** for 11 metrics: `hr, rmssd, sdnn, rsa, vti, lfhf, stress, rcmse, pip, dc, dfa1` (columns `before_*`, `during_*`, `after_*`). Scoped by `user_id`.

## Tools (read-only, token-scoped — mirror the SP3 session tools)

Both resolve `user_id` via `_auth(ctx)` (existing `resolve_bearer` on the request header); **no tool takes a user_id argument**; every query filters by `user_id`; `get_activity` verifies ownership.

1. **`list_activities(limit=50, since=None, until=None, activity_type=None)`** → the user's activities, newest first. Each: `{id, activity_type, activity_subtype, custom_name, started_at, ended_at, is_manual, impact_score, notes}`. `since`/`until` are ISO datetimes filtering `started_at` (reuse SP3's `_parse_dt`); `activity_type` optionally filters by type (e.g. "Breathwork"). `limit` capped (e.g. 200).

2. **`get_activity(activity_id)`** → one of the user's activities with the full metric grid:
   ```
   { id, activity_type, activity_subtype, custom_name, started_at, ended_at,
     is_manual, impact_score, notes,
     metrics: {
       hr:    {before, during, after},
       rmssd: {before, during, after},
       sdnn:  {...}, rsa: {...}, vti: {...}, lf_hf: {...}, stress: {...},
       rcmse: {...}, pip: {...}, dc: {...}, dfa1: {...}
     } }
   ```
   `activity_id` validated as a UUID (reuse SP3's `_valid_uuid`); `WHERE id = $1 AND user_id = $2`; raises `ValueError("activity not found")` on no match (same not-found-vs-not-owned indistinguishability as the session tools).

The `metrics` dict maps each metric name to its `before_*/during_*/after_*` columns. `stress` is the breathing-robust dial; `lf_hf` is the raw ratio — both are exposed (they're distinct columns).

## Implementation

In `server/mcp_server.py`, following the existing session-tool structure:
- `_activity_list_row(r)` — flat summary dict (no metric grid).
- `_activity_detail(r)` — summary + the nested `metrics` dict.
- `_list_activities(user_id, limit, since, until, activity_type)` and `_get_activity(user_id, activity_id)` — the async DB helpers (unit-testable).
- `@mcp.tool()` wrappers `list_activities` / `get_activity` with docstrings (Claude reads them), each calling `_auth(ctx)` then the helper.

No change to auth, mount, lifespan, or the existing session tools.

## Testing (mirror SP3's helper tests, in `server/tests/test_mcp.py`)

- Seed two users; insert an activity for user A (with a couple of metric columns set) directly via the pool.
- `_list_activities(A)` returns it; `_list_activities(B)` returns `[]`.
- `_get_activity(A, id)` returns the summary + `metrics` grid with the seeded values; `_get_activity(B, id)` raises `ValueError` (cross-user isolation).
- `list_activities` `activity_type` filter returns only matching types.
- Registration test updated to assert the two new tool names are present.
- Run with the `.venv313` + local Postgres harness (direct-pool fixture, per SP3).

## Deploy & verify

Server-only; the Hetzner deploy already runs on the box. After deploy, verify with the MCP client (as in SP3): connect with a token, `list_activities`, `get_activity` → confirm only the token-user's activities, with the metric grid.

## Out of scope

- All-day continuous metrics sync (SP5b — the large one) and daily summaries (SP5c).
- Any app change (activities already upload).
