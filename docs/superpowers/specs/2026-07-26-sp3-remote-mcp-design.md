# SP3 — Remote (server-side) MCP server — Design

**Goal:** Host one server-side MCP endpoint on the FastAPI backend so each user adds it to Claude Code with their own personal access token and gets read-only tools over **their own data, and only their own**. No local install, no per-user hosting.

**Status:** Approved decisions — ship now over the currently-synced data (sessions + per-session HRV samples); use the official MCP Python SDK (`FastMCP`, Streamable HTTP) mounted in FastAPI; per-request Bearer auth reusing SP1's token→user_id resolution.

**Depends on:** SP1 (done — `api_tokens`, `wyth_pat_` tokens, `current_user_id`, `/mcp` already exempt from the shared-key gate).

---

## How a user connects

```
claude mcp add --transport http wythin https://api.<host>/mcp \
  --header "Authorization: Bearer wyth_pat_xxxxx"
```

Claude Code sends that `Authorization` header on every MCP HTTP request. The server resolves the token → one `user_id` and scopes every tool's queries to it.

## Architecture

- Add the `mcp` package to `server/requirements.txt`.
- New module `server/mcp_server.py`: a `FastMCP(name="Wythin", stateless_http=True)` instance with the tools below. `stateless_http=True` means every request is independent — no cross-request session state — which is correct for per-request Bearer auth and safe under multiple uvicorn workers.
- Mount it in `server/main.py` at `/mcp` and run its session manager inside the existing lifespan:

  ```python
  # main.py
  from .mcp_server import mcp

  @asynccontextmanager
  async def lifespan(app: FastAPI):
      await init_pool()
      await create_schema()
      async with mcp.session_manager.run():
          yield
      await close_pool()

  # mount so the endpoint is exactly /mcp (set the server's internal
  # streamable_http_path to "/" so mount("/mcp") doesn't become /mcp/mcp)
  app.mount("/mcp", mcp.streamable_http_app())
  ```
- The SP1 gate already exempts `/mcp` (via `_bearer_exempt`), so the shared `X-API-Key` is not required; the MCP tools enforce the Bearer token themselves.

## Authentication — the isolation guarantee

Refactor SP1's inline token logic in `server/auth_user.py` into one reusable resolver so the FastAPI dependency and the MCP tools share exactly one code path:

```python
async def resolve_bearer(authorization: str | None) -> str:
    """Bearer 'wyth_pat_...' -> user_id, or raise. Rate-limited; updates last_used_at."""
    # (the body currently inside current_user_id, minus the Header() plumbing)

async def current_user_id(authorization: Optional[str] = Header(default=None)) -> str:
    return await resolve_bearer(authorization)
```

Each MCP tool reads the header from the request context and calls `resolve_bearer`:

```python
@mcp.tool()
async def list_sessions(ctx: Context, limit: int = 50) -> list[dict]:
    user_id = await resolve_bearer(ctx.request_context.request.headers.get("authorization"))
    # ... query WHERE user_id = $1 ...
```

**Invariants (the whole point of SP3):**
- Every tool resolves `user_id` from the token on the server. **No tool accepts a `user_id`/device argument.**
- Every query filters by that `user_id`. Session-scoped tools additionally verify the session belongs to the user (`WHERE user_id = $1 AND id = $2`).
- Missing / malformed / unknown / revoked token → the tool raises an auth error (no data returned).

## Tools (read-only, over current data)

Data available server-side today: `sessions` (summaries) and `hrv_samples` (per-sample rows within a session). Tools:

1. **`whoami()`** → `{id, display_name, created_at}` — sanity check that auth works.
2. **`list_sessions(limit=50, since=None, until=None)`** → the user's sessions, newest first: `{id, started_at, ended_at, avg_rsa_ms, avg_coherence, best_resonance_bpm, notes}`. `since`/`until` are ISO date strings.
3. **`get_session(session_id)`** → one session summary (404-style error if not the user's).
4. **`get_session_samples(session_id, limit=2000)`** → per-sample HRV within one of the user's sessions: `{ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi, breath_bpm}`.

Each tool has a clear docstring (Claude reads these as the tool description). Numeric limits are capped server-side.

When SP5 lands (activities, all-day metrics, the 9 advanced metrics, daily summaries), new tools are added over the new tables — no change to the auth or transport layer.

## Testing

- Reuse the SP1 test harness (`_client()` + local Postgres). MCP tools call plain async functions; test the **tool functions directly** by extracting the query bodies into small `async def` helpers in `mcp_server.py` (e.g. `_list_sessions(user_id, ...)`) that the `@mcp.tool()` wrappers call after auth — the helpers are unit-testable without driving the MCP transport.
- Auth: a tool called with no / bogus / revoked token raises; with a valid token returns only that user's rows.
- Scoping: user A's token cannot read user B's session or its samples (`get_session`/`get_session_samples` with another user's session id → error, not data).
- A lightweight transport smoke check: `POST /mcp` `initialize` returns 200 and lists the tools (proves the mount + lifespan wire up). Kept minimal — the data logic is covered by the helper tests.

## Deploy

`server/requirements.txt` gains `mcp`; the Hetzner deploy already runs `pip install -r server/requirements.txt`. `stateless_http=True` keeps it correct under the prod uvicorn workers. No app (iOS) change. After deploy, verify with `claude mcp add --transport http wythin https://api.<host>/mcp --header "Authorization: Bearer <a real token>"` then a tool call.

## Out of scope for SP3

- New synced data types (SP5).
- Write tools (read-only only).
- The in-app "API Access" screen that mints tokens (SP4) — for now tokens are minted via `POST /v1/tokens`.
- Rate-limiter hardening (shared store / validate-before-record) — carried over from SP1's deferred list.
