# SP3 — Remote server-side MCP endpoint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host one server-side MCP endpoint at `/mcp` so each user adds it to Claude Code with their personal access token and gets read-only, token-scoped tools over their own sessions and HRV samples.

**Architecture:** A `FastMCP(stateless_http=True, streamable_http_path="/")` server (`server/mcp_server.py`) mounted at `/mcp` in the existing FastAPI app, with its session manager run inside the app lifespan. Each tool resolves the caller's `user_id` from the request's `Authorization: Bearer` header using the SP1 token logic (refactored into a shared `resolve_bearer`), and every query is scoped to that user_id. SP1 already exempts `/mcp` from the shared-key gate.

**Tech Stack:** FastAPI, asyncpg, PostgreSQL, the official MCP Python SDK (`mcp`, FastMCP + Streamable HTTP), pytest + asgi-lifespan + httpx.

## Global Constraints

- **Python 3.10+** (production runs 3.14; the MCP SDK requires ≥3.10). The old 3.9 dev venv cannot run this — use the 3.13 test venv at `.venv313` for all SP3 test commands: `.venv313/bin/pytest`, `.venv313/bin/python`. A local Postgres is running with a `wythin_test` DB; run DB tests with `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest ...`.
- Endpoint is exactly `/mcp` — set `streamable_http_path="/"` and `app.mount("/mcp", mcp.streamable_http_app())` (do NOT let it become `/mcp/mcp`).
- `session_manager` is created lazily by `streamable_http_app()`; the `app.mount(...)` call (module import time) must run before the lifespan accesses `mcp.session_manager`.
- **Isolation guarantee:** every tool resolves `user_id` from the token on the server; **no tool accepts a user_id/device argument**; every query filters by that user_id; session-scoped tools verify ownership (`WHERE id = $1 AND user_id = $2`). Missing/malformed/unknown/revoked token → the tool raises (no data).
- Read-only. Data available now: `sessions` and `hrv_samples` only.
- Reuse ONE auth path: `resolve_bearer(authorization) -> user_id` shared by the FastAPI dependency (`current_user_id`) and the MCP tools.
- Keep `from __future__ import annotations`. Follow existing asyncpg patterns (`get_pool()`, str user id into uuid params).

## File Structure

- Modify `server/requirements.txt` — add `mcp>=1.12`.
- Modify `server/auth_user.py` — add `AuthError` + `resolve_bearer`; `current_user_id` delegates to it.
- Create `server/mcp_server.py` — the `FastMCP` instance, data helpers, and `@mcp.tool()` wrappers.
- Modify `server/main.py` — import `mcp`, run `mcp.session_manager.run()` in the lifespan, `app.mount("/mcp", mcp.streamable_http_app())`.
- Create `server/tests/test_mcp.py` — resolve_bearer, tool-helper scoping, and wiring/registration tests.

---

### Task 1: Add MCP dependency + shared `resolve_bearer` auth

**Files:**
- Modify: `server/requirements.txt`
- Modify: `server/auth_user.py`
- Test: `server/tests/test_mcp.py` (resolve_bearer portion)

**Interfaces:**
- Produces: `class AuthError(Exception)` with `.status: int` and `.detail: str`; `async def resolve_bearer(authorization: str | None) -> str` (raises `AuthError`); `current_user_id` unchanged in behavior (still raises `HTTPException`).

- [ ] **Step 1: Write the failing test** — create `server/tests/test_mcp.py`:

```python
from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
from asgi_lifespan import LifespanManager
from httpx import AsyncClient, ASGITransport
from server.main import app


@asynccontextmanager
async def _client():
    async with LifespanManager(app) as manager:
        async with AsyncClient(transport=ASGITransport(app=manager.app), base_url="http://test") as c:
            yield c


@pytest.mark.asyncio
async def test_resolve_bearer_valid_and_invalid():
    from server.auth_user import resolve_bearer, AuthError
    async with _client() as c:
        made = (await c.post("/v1/tokens", json={"name": "mcp"},
                             headers={"X-User-ID": "mcp-auth-user"})).json()
        raw = made["token"]
        # Valid
        uid = await resolve_bearer(f"Bearer {raw}")
        assert isinstance(uid, str) and uid
        # Missing / malformed
        with pytest.raises(AuthError):
            await resolve_bearer(None)
        with pytest.raises(AuthError):
            await resolve_bearer("Bearer not-a-wyth-token")
        # Revoked → AuthError
        await c.delete(f"/v1/tokens/{made['id']}", headers={"X-User-ID": "mcp-auth-user"})
        with pytest.raises(AuthError):
            await resolve_bearer(f"Bearer {raw}")
```

- [ ] **Step 2: Run it — confirm it fails**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest server/tests/test_mcp.py::test_resolve_bearer_valid_and_invalid -v`
Expected: FAIL (`ImportError: cannot import name 'resolve_bearer'`).

- [ ] **Step 3: Refactor `server/auth_user.py`**

Add `AuthError`, extract `resolve_bearer`, delegate from `current_user_id`:

```python
class AuthError(Exception):
    """Auth failure carrying an HTTP-ish status so callers can map it."""
    def __init__(self, status: int, detail: str):
        self.status = status
        self.detail = detail
        super().__init__(detail)


async def resolve_bearer(authorization: str | None) -> str:
    """Resolve 'Bearer wyth_pat_...' to a user_id, or raise AuthError.
    Rate-limited per token; updates last_used_at on success."""
    if not authorization or not authorization.startswith("Bearer "):
        raise AuthError(401, "missing bearer token")
    raw = authorization[len("Bearer "):].strip()
    if not raw.startswith(TOKEN_PREFIX):
        raise AuthError(401, "invalid token")
    token_hash = hash_token(raw)
    if not _allow(token_hash):
        raise AuthError(429, "rate limit exceeded")
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT user_id, revoked_at FROM api_tokens WHERE token_sha256 = $1",
            token_hash,
        )
        if row is None or row["revoked_at"] is not None:
            raise AuthError(401, "invalid or revoked token")
        await conn.execute(
            "UPDATE api_tokens SET last_used_at = NOW() WHERE token_sha256 = $1",
            token_hash,
        )
    return str(row["user_id"])


async def current_user_id(authorization: Optional[str] = Header(default=None)) -> str:
    try:
        return await resolve_bearer(authorization)
    except AuthError as e:
        raise HTTPException(status_code=e.status, detail=e.detail)
```

Remove the old inline body of `current_user_id` (now delegated). Keep `_allow`, `_hits`, `_RATE_LIMIT`, `_WINDOW`, imports.

- [ ] **Step 4: Add the dependency to `server/requirements.txt`**

Append: `mcp>=1.12`

- [ ] **Step 5: Run tests — verify green + no regressions**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest server/tests/test_mcp.py::test_resolve_bearer_valid_and_invalid server/tests/test_tokens.py -v`
Expected: PASS (resolve_bearer test + all existing token tests — `current_user_id` behavior unchanged).

- [ ] **Step 6: Commit**

```bash
git add server/requirements.txt server/auth_user.py server/tests/test_mcp.py
git commit -m "feat(mcp): shared resolve_bearer auth + add mcp dependency"
```

---

### Task 2: MCP server, tools, and mount

**Files:**
- Create: `server/mcp_server.py`
- Modify: `server/main.py`
- Test: `server/tests/test_mcp.py`

**Interfaces:**
- Consumes: `resolve_bearer` (Task 1), `get_pool()`, `get_or_create_user`.
- Produces: `mcp` (FastMCP); data helpers `_whoami(user_id)`, `_list_sessions(user_id, limit, since, until)`, `_get_session(user_id, session_id)`, `_get_session_samples(user_id, session_id, limit)`; tools `whoami`, `list_sessions`, `get_session`, `get_session_samples` mounted at `/mcp`.

- [ ] **Step 1: Write the failing tests** — append to `server/tests/test_mcp.py`:

```python
@pytest.mark.asyncio
async def test_tool_helpers_scope_to_user():
    from server.db import get_or_create_user, get_pool
    from server.mcp_server import (
        _list_sessions, _get_session, _get_session_samples, _whoami,
    )
    async with LifespanManager(app):
        uid_a = await get_or_create_user("mcp-scope-A")
        uid_b = await get_or_create_user("mcp-scope-B")
        async with get_pool().acquire() as conn:
            sid = await conn.fetchval(
                "INSERT INTO sessions (user_id, started_at, avg_rsa_ms) "
                "VALUES ($1, NOW(), 30) RETURNING id", uid_a)
            await conn.execute(
                "INSERT INTO hrv_samples (session_id, ts, mean_bpm, rmssd) "
                "VALUES ($1, NOW(), 62, 40)", str(sid))

        # A sees exactly its session; B sees none
        assert len(await _list_sessions(uid_a, 50, None, None)) == 1
        assert await _list_sessions(uid_b, 50, None, None) == []

        # Ownership enforced: B cannot read A's session or samples
        with pytest.raises(ValueError):
            await _get_session(uid_b, str(sid))
        with pytest.raises(ValueError):
            await _get_session_samples(uid_b, str(sid))

        # A can
        assert (await _get_session(uid_a, str(sid)))["id"] == str(sid)
        assert len(await _get_session_samples(uid_a, str(sid))) == 1
        assert (await _whoami(uid_a))["id"] == uid_a


@pytest.mark.asyncio
async def test_mcp_tools_registered_and_mounted():
    from server.mcp_server import mcp
    tools = {t.name for t in await mcp.list_tools()}
    assert {"whoami", "list_sessions", "get_session", "get_session_samples"} <= tools
    assert any(getattr(r, "path", "") == "/mcp" for r in app.routes)
```

- [ ] **Step 2: Run — confirm it fails**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest server/tests/test_mcp.py -v`
Expected: FAIL (`ModuleNotFoundError: server.mcp_server`).

- [ ] **Step 3: Create `server/mcp_server.py`**

```python
"""Server-side MCP endpoint: read-only, token-scoped tools over the caller's
own sessions and HRV samples. Mounted at /mcp by server.main.

Every tool resolves the user_id from the request's Authorization header and
scopes all queries to it — no tool accepts a user_id argument.
"""
from __future__ import annotations

import uuid as _uuid
from datetime import datetime
from typing import Optional

from mcp.server.fastmcp import Context, FastMCP

from .auth_user import resolve_bearer
from .db import get_pool

mcp = FastMCP(name="Wythin", stateless_http=True, streamable_http_path="/")

_MAX_SESSIONS = 200
_MAX_SAMPLES = 5000


def _parse_dt(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _valid_uuid(s: str) -> str:
    try:
        return str(_uuid.UUID(s))
    except (ValueError, AttributeError, TypeError):
        raise ValueError("invalid session id")


async def _auth(ctx: Context) -> str:
    request = ctx.request_context.request
    header = request.headers.get("authorization") if request is not None else None
    return await resolve_bearer(header)


def _session_row(r) -> dict:
    return {
        "id": str(r["id"]),
        "started_at": r["started_at"].isoformat() if r["started_at"] else None,
        "ended_at": r["ended_at"].isoformat() if r["ended_at"] else None,
        "best_resonance_bpm": r["best_resonance_bpm"],
        "avg_rsa_ms": r["avg_rsa_ms"],
        "avg_coherence": r["avg_coherence"],
        "notes": r["notes"],
    }


# ---- data helpers (unit-testable without the MCP transport) ----

async def _whoami(user_id: str) -> dict:
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, display_name, created_at FROM users WHERE id = $1", user_id)
    if row is None:
        return {}
    return {"id": str(row["id"]), "display_name": row["display_name"],
            "created_at": row["created_at"].isoformat()}


async def _list_sessions(user_id: str, limit: int, since: Optional[str], until: Optional[str]) -> list[dict]:
    limit = max(1, min(int(limit), _MAX_SESSIONS))
    clauses = ["user_id = $1"]
    args: list = [user_id]
    dt_since, dt_until = _parse_dt(since), _parse_dt(until)
    if dt_since is not None:
        args.append(dt_since); clauses.append(f"started_at >= ${len(args)}")
    if dt_until is not None:
        args.append(dt_until); clauses.append(f"started_at < ${len(args)}")
    args.append(limit)
    sql = (
        "SELECT id, started_at, ended_at, best_resonance_bpm, avg_rsa_ms, avg_coherence, notes "
        "FROM sessions WHERE " + " AND ".join(clauses) +
        f" ORDER BY started_at DESC LIMIT ${len(args)}"
    )
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(sql, *args)
    return [_session_row(r) for r in rows]


async def _get_session(user_id: str, session_id: str) -> dict:
    sid = _valid_uuid(session_id)
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, started_at, ended_at, best_resonance_bpm, avg_rsa_ms, avg_coherence, notes "
            "FROM sessions WHERE id = $1 AND user_id = $2", sid, user_id)
    if row is None:
        raise ValueError("session not found")
    return _session_row(row)


async def _get_session_samples(user_id: str, session_id: str, limit: int) -> list[dict]:
    sid = _valid_uuid(session_id)
    limit = max(1, min(int(limit), _MAX_SAMPLES))
    async with get_pool().acquire() as conn:
        owns = await conn.fetchval(
            "SELECT 1 FROM sessions WHERE id = $1 AND user_id = $2", sid, user_id)
        if not owns:
            raise ValueError("session not found")
        rows = await conn.fetch(
            "SELECT ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi, breath_bpm "
            "FROM hrv_samples WHERE session_id = $1 ORDER BY ts LIMIT $2", sid, limit)
    return [
        {
            "ts": r["ts"].isoformat() if r["ts"] else None,
            "mean_bpm": r["mean_bpm"], "rmssd": r["rmssd"], "sdnn": r["sdnn"],
            "pnn50": r["pnn50"], "lf_hf": r["lf_hf"], "rsa_ms": r["rsa_ms"],
            "coherence": r["coherence"], "cbi": r["cbi"], "breath_bpm": r["breath_bpm"],
        }
        for r in rows
    ]


# ---- MCP tools (thin auth wrappers over the helpers) ----

@mcp.tool()
async def whoami(ctx: Context) -> dict:
    """Return your Wythin account info (id, display name). Confirms your token works."""
    return await _whoami(await _auth(ctx))


@mcp.tool()
async def list_sessions(ctx: Context, limit: int = 50,
                        since: Optional[str] = None, until: Optional[str] = None) -> list[dict]:
    """List your recorded HRV/breathing sessions, newest first.
    limit caps the count; since/until are ISO-8601 datetimes filtering by start time."""
    return await _list_sessions(await _auth(ctx), limit, since, until)


@mcp.tool()
async def get_session(ctx: Context, session_id: str) -> dict:
    """Get the summary of one of your sessions by its id."""
    return await _get_session(await _auth(ctx), session_id)


@mcp.tool()
async def get_session_samples(ctx: Context, session_id: str, limit: int = 2000) -> list[dict]:
    """Get the per-sample HRV rows (chronological) within one of your sessions."""
    return await _get_session_samples(await _auth(ctx), session_id, limit)
```

- [ ] **Step 4: Wire into `server/main.py`**

Add the import near the others:
```python
from .mcp_server import mcp
```
Update the lifespan to run the session manager (keep init/close pool):
```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    await create_schema()
    async with mcp.session_manager.run():
        yield
    await close_pool()
```
Mount the MCP app once, after the other routers are included (module level):
```python
app.mount("/mcp", mcp.streamable_http_app())
```

- [ ] **Step 5: Run the full MCP test file + suite — verify green**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test .venv313/bin/pytest server/tests/ -v`
Expected: PASS (all — existing 16 + new MCP tests). Output pristine.

- [ ] **Step 6: Commit**

```bash
git add server/mcp_server.py server/main.py server/tests/test_mcp.py
git commit -m "feat(mcp): remote /mcp server with token-scoped read-only tools"
```

---

## Self-Review notes

- **Spec coverage:** shared `resolve_bearer` (T1); FastMCP mounted at `/mcp` with lazy session_manager ordered correctly (T2 Step 4); 4 read-only tools, no user_id args, ownership checks, scoping tests (T2); read-only; data limited to sessions + hrv_samples.
- **Isolation:** helper tests prove user B cannot read user A's session/samples; tool wrappers only pass the token-derived user_id.
- **Type/pattern consistency:** str user_id → asyncpg uuid params (as in sessions.py); `_parse_dt` mirrors sessions.py; `_valid_uuid` guards malformed ids (avoids raw DataError).
- **Deploy:** `mcp>=1.12` added to `server/requirements.txt`; Hetzner deploy + CI already `pip install -r server/requirements.txt` (prod 3.14, CI 3.12 — both ≥3.10). No iOS change. Verify post-deploy with `claude mcp add --transport http wythin https://api.<host>/mcp --header "Authorization: Bearer <real token>"`.
- **Known deferred (from SP1, unchanged):** rate limiter in-memory/per-process.
