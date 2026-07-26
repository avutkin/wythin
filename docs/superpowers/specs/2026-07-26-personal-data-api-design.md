# Wythin Personal Data API — Design

**Goal:** Let each Wythin user access **their own data, and only their own data**,
from Claude Code, via a remote MCP server authenticated by a per-user personal
access token they generate in the app.

**Status:** Approved decisions — remote MCP server; expand server-side sync to the
full dataset; in-app self-service token issuance; read-only access.

---

## Architecture overview

```
Claude Code ──(claude mcp add --transport http, Bearer token)──► /mcp  ─┐
                                                                        │  same
curl / scripts ──(Authorization: Bearer)──► /v1/me/* REST ─────────────┤  FastAPI
                                                                        │  backend
iOS app ──(create/revoke token, existing sync)──► /v1/tokens, /sessions ┘
                                                        │
                                                   PostgreSQL (scoped by user_id)
```

Every request from Claude Code carries the user's personal access token. The
backend resolves token → `user_id` and scopes **every** query to that id, so a
token can never read another user's rows. The MCP server and the REST API are two
faces of the same scoped data layer on the existing Hetzner backend.

## Sub-project decomposition & build order

| # | Sub-project | Depends on | Effort |
|---|---|---|---|
| **SP1** | Per-user auth foundation (this spec) | — | S |
| **SP2** | Read-only `/v1/me/*` REST API + `openapi.json` | SP1 | S–M |
| **SP3** | Remote MCP server (`/mcp`) exposing typed tools | SP1, SP2 | M |
| **SP4** | In-app "API Access" screen (create/copy/revoke, show setup command) | SP1 | S |
| **SP5** | Expand server-side sync (activities, all-day metrics, 9 advanced metrics, daily summaries) | — (parallel) | L |

**MVP path:** SP1 → SP2 → SP3 → SP4 = working end-to-end Claude Code access over
the data already synced (sessions). SP5 then enriches the returned data
incrementally, one data type at a time.

## Data available now vs. after SP5

- **Now (server-side):** `sessions` (summaries) and `hrv_samples` (per-sample
  HR/RMSSD/SDNN/pnn50/LF-HF/RSA/coherence/CBI/breath, within sessions only).
- **On-device only (needs SP5 to expose):** the 9 advanced metrics (DC, RCMSE,
  PIP, DFA α1, VTI, …), continuous all-day history, activities + AI insights, the
  onboarding profile.

## Privacy posture (decide before SP5)

SP1–SP4 change only **how existing data is accessed**, not what is stored — safe to
build first. SP5 stores substantially more personal health data server-side; before
it, decide: encryption at rest, retention window, and export/delete rights. Tracked
as a gate on SP5, not SP1.

---

# SP1 — Per-user auth foundation (this sub-project)

**Deliverable:** a per-user personal-access-token system that authenticates a caller
as exactly one `user_id`, plus issuance/revoke/list endpoints for the app, and a
dependency that scoped routes use to get the authenticated user. Closes the current
unauthenticated-`X-User-ID` hole.

## Token model

- **Format shown to user:** `wyth_pat_<43 base64url chars>` (32 random bytes). The
  prefix makes tokens greppable and lets us detect leaked tokens later.
- **Storage:** never store the raw token. Store `token_sha256` (hex), `user_id`,
  `name` (user label, e.g. "Claude Code"), `created_at`, `last_used_at`, `revoked_at`.
  Lookup is by SHA-256 of the presented token (constant-time compare on the row).
- **Scope:** read-only. (A `scopes` column is included now, defaulting to `read`, so
  write scopes can be added later without a migration.)

### Schema (added to `server/db.py` SCHEMA_SQL — idempotent)

```sql
CREATE TABLE IF NOT EXISTS api_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_sha256 TEXT UNIQUE NOT NULL,      -- hex SHA-256 of the raw token
    name         TEXT,                      -- user-facing label
    scopes       TEXT NOT NULL DEFAULT 'read',
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS api_tokens_user ON api_tokens(user_id) WHERE revoked_at IS NULL;
```

## Auth dependency

`server/auth_user.py` — a FastAPI dependency `current_user_id(authorization: Header)`:

1. Require `Authorization: Bearer wyth_pat_...`; else `401`.
2. `h = sha256(raw).hexdigest()`; `SELECT user_id, revoked_at FROM api_tokens WHERE token_sha256 = h`.
3. If no row or `revoked_at IS NOT NULL` → `401`.
4. Best-effort `UPDATE api_tokens SET last_used_at = NOW()` (fire-and-forget).
5. Return `user_id`.

The existing shared `X-API-Key` gate stays for app-only routes; the new
`/v1/*` routes use `current_user_id` instead. `/sessions` is migrated to derive
`user_id` from the token rather than the client `X-User-ID` header (removes the
spoofing hole); the app starts sending the token.

## Token issuance API (used by SP4's in-app screen)

All of these are authenticated as the app is today (device/Apple identity → `user_id`);
they operate on the caller's own tokens only.

- `POST /v1/tokens` `{ "name": "Claude Code" }` → **`{ "token": "wyth_pat_...", "id": ..., "name": ..., "created_at": ... }`**. The raw token is returned **once**; only its hash is stored.
- `GET /v1/tokens` → list the caller's tokens (id, name, created_at, last_used_at) — **never** the raw token.
- `DELETE /v1/tokens/{id}` → set `revoked_at = NOW()` for a token owned by the caller.

## Rate limiting

Per-token fixed-window limiter (e.g. 120 req/min) in the auth dependency, keyed by
`token_sha256`. In-memory to start (single box); documented as needing Redis if the
backend scales horizontally.

## Testing (SP1 acceptance)

- Valid token → dependency returns the right `user_id`; `last_used_at` updates.
- Missing / malformed / unknown / revoked token → `401`.
- Two users, two tokens: user A's token cannot read user B's rows (scoping test on a
  representative `/sessions` query).
- `POST /v1/tokens` returns a raw token once; a second `GET` never exposes it.
- `DELETE` revokes: the token then `401`s.
- Rate limit: N+1 requests in the window → `429`.

## Out of scope for SP1

Endpoints that read data (`/v1/me/*`) — SP2. MCP — SP3. In-app UI — SP4. New synced
data types — SP5.
```
