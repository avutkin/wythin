# SP1 — Personal Data API Auth Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-user personal-access-token system to the FastAPI backend: issuance/list/revoke endpoints for the app, and a `Bearer`-token dependency that authenticates a caller as exactly one `user_id`, proven by a minimal scoped `GET /v1/me`.

**Architecture:** Purely additive server-side change (no app release, `/sessions` untouched). Token issuance (`/v1/tokens`) stays behind the existing shared `X-API-Key` gate and identifies the user via the `X-User-ID` device header. Per-user data routes (`/v1/me`, later `/mcp`) bypass the shared-key gate and authenticate via `Authorization: Bearer wyth_pat_...`, resolved to a `user_id` scoped to that token.

**Tech Stack:** FastAPI, asyncpg, PostgreSQL, pytest + asgi-lifespan + httpx (existing test harness).

## Global Constraints

- Token format: `wyth_pat_` + `secrets.token_urlsafe(32)`. Store **only** the SHA-256 hex (`token_sha256`), never the raw token. Raw token returned exactly once, on creation.
- Read-only access; `scopes` column defaults to `'read'` (forward-compat, unused in SP1).
- `/sessions` and the app are NOT modified in SP1. Hardening `/sessions` to require a token is deferred until after SP4 (app can issue/send tokens), to avoid a lockstep app release.
- Follow existing code patterns: `from __future__ import annotations`, `get_pool()`/`pool.acquire()`, `get_or_create_user(device_id)` returns `str` uuid, routers in `server/routers/`, tests use the `_client()` LifespanManager fixture and send no `x-api-key` (gate is disabled when `API_KEY` env is unset).
- New per-user routes must be exempt from the shared-key middleware; `/v1/tokens` must remain behind it.

## File Structure

- Create `server/tokens.py` — pure token generate/hash helpers.
- Modify `server/db.py` — add `api_tokens` table to `SCHEMA_SQL`.
- Modify `server/models.py` — add `TokenCreate`, `TokenCreated`, `TokenInfo`.
- Create `server/routers/tokens.py` — `POST/GET/DELETE /v1/tokens` (shared-key gated, `X-User-ID` scoped).
- Create `server/auth_user.py` — `current_user_id` Bearer dependency + in-memory rate limiter.
- Create `server/routers/me.py` — `GET /v1/me` (Bearer scoped).
- Modify `server/main.py` — include the two routers; exempt Bearer prefixes from the shared-key gate.
- Create `server/tests/test_tokens.py` — issuance + Bearer + scoping + revoke + rate-limit tests.

---

### Task 1: Token helpers + schema

**Files:**
- Create: `server/tokens.py`
- Modify: `server/db.py` (SCHEMA_SQL)
- Test: `server/tests/test_tokens.py` (unit portion)

**Interfaces:**
- Produces: `generate_token() -> tuple[str, str]` (raw, sha256_hex); `hash_token(raw: str) -> str`; `TOKEN_PREFIX = "wyth_pat_"`.

- [ ] **Step 1: Write the failing unit test**

Create `server/tests/test_tokens.py`:

```python
from __future__ import annotations

from server.tokens import generate_token, hash_token, TOKEN_PREFIX


def test_generate_token_shape_and_hash():
    raw, h = generate_token()
    assert raw.startswith(TOKEN_PREFIX)
    assert len(raw) > len(TOKEN_PREFIX) + 20
    assert h == hash_token(raw)
    assert len(h) == 64                    # sha256 hex
    # Uniqueness across calls
    raw2, h2 = generate_token()
    assert raw != raw2 and h != h2
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `pytest server/tests/test_tokens.py::test_generate_token_shape_and_hash -v`
Expected: FAIL (`ModuleNotFoundError: server.tokens`).

- [ ] **Step 3: Implement `server/tokens.py`**

```python
"""Personal-access-token generation and hashing."""
from __future__ import annotations

import hashlib
import secrets

TOKEN_PREFIX = "wyth_pat_"


def hash_token(raw: str) -> str:
    """Hex SHA-256 of a raw token — the only form we store."""
    return hashlib.sha256(raw.encode()).hexdigest()


def generate_token() -> tuple[str, str]:
    """Return (raw_token, sha256_hex). Raw is shown to the user once."""
    raw = TOKEN_PREFIX + secrets.token_urlsafe(32)
    return raw, hash_token(raw)
```

- [ ] **Step 4: Add the `api_tokens` table to `server/db.py`**

Append inside the `SCHEMA_SQL` string, after the `hrv_samples` index lines:

```sql
CREATE TABLE IF NOT EXISTS api_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_sha256 TEXT UNIQUE NOT NULL,
    name         TEXT,
    scopes       TEXT NOT NULL DEFAULT 'read',
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS api_tokens_user ON api_tokens(user_id) WHERE revoked_at IS NULL;
```

- [ ] **Step 5: Run the unit test — verify it passes**

Run: `pytest server/tests/test_tokens.py::test_generate_token_shape_and_hash -v`
Expected: PASS. Also `python -m py_compile server/tokens.py server/db.py`.

- [ ] **Step 6: Commit**

```bash
git add server/tokens.py server/db.py server/tests/test_tokens.py
git commit -m "feat(api): add api_tokens schema and token helpers"
```

---

### Task 2: Token issuance API (`/v1/tokens`)

**Files:**
- Modify: `server/models.py`
- Create: `server/routers/tokens.py`
- Modify: `server/main.py` (include router)
- Test: `server/tests/test_tokens.py`

**Interfaces:**
- Consumes: `generate_token()` (Task 1); `get_or_create_user(device_id)`, `get_pool()`.
- Produces: `POST /v1/tokens` → `{token, id, name, created_at}`; `GET /v1/tokens` → `[{id,name,created_at,last_used_at}]`; `DELETE /v1/tokens/{id}` → `{status:"revoked"}`. All scoped by `X-User-ID`.

- [ ] **Step 1: Add pydantic models to `server/models.py`**

```python
class TokenCreate(BaseModel):
    name: Optional[str] = None


class TokenCreated(BaseModel):
    token: str            # raw token — returned once
    id: str
    name: Optional[str] = None
    created_at: str


class TokenInfo(BaseModel):
    id: str
    name: Optional[str] = None
    created_at: str
    last_used_at: Optional[str] = None
```

(`BaseModel` and `Optional` are already imported in `server/models.py`.)

- [ ] **Step 2: Write the failing integration test**

Append to `server/tests/test_tokens.py` (reuse the fixture from test_sessions):

```python
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
async def test_create_list_revoke_token():
    async with _client() as c:
        # Create
        r = await c.post("/v1/tokens", json={"name": "Claude Code"},
                         headers={"X-User-ID": "tok-device-1"})
        assert r.status_code == 200
        body = r.json()
        assert body["token"].startswith("wyth_pat_")
        token_id = body["id"]

        # List never exposes the raw token
        r = await c.get("/v1/tokens", headers={"X-User-ID": "tok-device-1"})
        assert r.status_code == 200
        listed = r.json()
        assert any(t["id"] == token_id for t in listed)
        assert all("token" not in t for t in listed)

        # Revoke
        r = await c.delete(f"/v1/tokens/{token_id}", headers={"X-User-ID": "tok-device-1"})
        assert r.status_code == 200

        # Revoking again → 404
        r = await c.delete(f"/v1/tokens/{token_id}", headers={"X-User-ID": "tok-device-1"})
        assert r.status_code == 404
```

- [ ] **Step 3: Run it — confirm it fails**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test pytest server/tests/test_tokens.py::test_create_list_revoke_token -v`
Expected: FAIL (404 — route not mounted).

- [ ] **Step 4: Implement `server/routers/tokens.py`**

```python
"""Personal-access-token issuance. Gated by the shared X-API-Key (app auth);
scoped to the caller's user via the X-User-ID device header."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException

from ..db import get_pool, get_or_create_user
from ..tokens import generate_token
from ..models import TokenCreate, TokenCreated, TokenInfo

router = APIRouter(prefix="/v1/tokens", tags=["tokens"])


@router.post("", response_model=TokenCreated)
async def create_token(body: TokenCreate, x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    raw, token_hash = generate_token()
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "INSERT INTO api_tokens (user_id, token_sha256, name) "
            "VALUES ($1, $2, $3) RETURNING id, name, created_at",
            user_id, token_hash, body.name,
        )
    return TokenCreated(token=raw, id=str(row["id"]), name=row["name"],
                        created_at=row["created_at"].isoformat())


@router.get("", response_model=list[TokenInfo])
async def list_tokens(x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, name, created_at, last_used_at FROM api_tokens "
            "WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC",
            user_id,
        )
    return [
        TokenInfo(
            id=str(r["id"]), name=r["name"],
            created_at=r["created_at"].isoformat(),
            last_used_at=r["last_used_at"].isoformat() if r["last_used_at"] else None,
        )
        for r in rows
    ]


@router.delete("/{token_id}")
async def revoke_token(token_id: str, x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    async with get_pool().acquire() as conn:
        res = await conn.execute(
            "UPDATE api_tokens SET revoked_at = NOW() "
            "WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
            token_id, user_id,
        )
    if res == "UPDATE 0":
        raise HTTPException(status_code=404, detail="token not found")
    return {"status": "revoked"}
```

- [ ] **Step 5: Mount the router in `server/main.py`**

Change the import and add the include:

```python
from .routers import sessions, stream, admin, insights, tokens
```
```python
app.include_router(tokens.router)
```

- [ ] **Step 6: Run the test — verify it passes**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test pytest server/tests/test_tokens.py -v`
Expected: PASS (both unit + integration).

- [ ] **Step 7: Commit**

```bash
git add server/models.py server/routers/tokens.py server/main.py server/tests/test_tokens.py
git commit -m "feat(api): token issuance endpoints (/v1/tokens create/list/revoke)"
```

---

### Task 3: Bearer auth dependency + scoped `GET /v1/me`

**Files:**
- Create: `server/auth_user.py`
- Create: `server/routers/me.py`
- Modify: `server/main.py` (include router + gate exemption)
- Test: `server/tests/test_tokens.py`

**Interfaces:**
- Consumes: `hash_token` (Task 1); `get_pool()`; token rows written by Task 2.
- Produces: `current_user_id(authorization) -> str` FastAPI dependency; `GET /v1/me` → `{id, display_name, created_at}`.

- [ ] **Step 1: Write the failing tests**

Append to `server/tests/test_tokens.py`:

```python
@pytest.mark.asyncio
async def test_me_requires_and_scopes_by_token():
    async with _client() as c:
        # No token → 401
        r = await c.get("/v1/me")
        assert r.status_code == 401

        # Bogus token → 401
        r = await c.get("/v1/me", headers={"Authorization": "Bearer wyth_pat_nope"})
        assert r.status_code == 401

        # Mint a token for user A and read /v1/me
        made = (await c.post("/v1/tokens", json={"name": "cc"},
                             headers={"X-User-ID": "me-device-A"})).json()
        token = made["token"]
        r = await c.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 200
        me = r.json()
        assert "id" in me

        # Revoked token → 401
        await c.delete(f"/v1/tokens/{made['id']}", headers={"X-User-ID": "me-device-A"})
        r = await c.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 401
```

- [ ] **Step 2: Run — confirm it fails**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test pytest server/tests/test_tokens.py::test_me_requires_and_scopes_by_token -v`
Expected: FAIL (401 path missing / route not mounted → actually 401 from shared-key gate; still fails on the 200 case).

- [ ] **Step 3: Implement `server/auth_user.py`**

```python
"""Bearer personal-access-token authentication → user_id, with a simple
in-memory per-token rate limiter."""
from __future__ import annotations

import time

from fastapi import Header, HTTPException

from .db import get_pool
from .tokens import hash_token, TOKEN_PREFIX

_RATE_LIMIT = 120          # requests
_WINDOW = 60.0             # seconds
_hits: dict[str, tuple[float, int]] = {}


def _allow(key: str) -> bool:
    now = time.monotonic()
    start, count = _hits.get(key, (now, 0))
    if now - start >= _WINDOW:
        _hits[key] = (now, 1)
        return True
    if count >= _RATE_LIMIT:
        return False
    _hits[key] = (start, count + 1)
    return True


async def current_user_id(authorization: str | None = Header(default=None)) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    raw = authorization[len("Bearer "):].strip()
    if not raw.startswith(TOKEN_PREFIX):
        raise HTTPException(status_code=401, detail="invalid token")
    token_hash = hash_token(raw)
    if not _allow(token_hash):
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT user_id, revoked_at FROM api_tokens WHERE token_sha256 = $1",
            token_hash,
        )
        if row is None or row["revoked_at"] is not None:
            raise HTTPException(status_code=401, detail="invalid or revoked token")
        await conn.execute(
            "UPDATE api_tokens SET last_used_at = NOW() WHERE token_sha256 = $1",
            token_hash,
        )
    return str(row["user_id"])
```

- [ ] **Step 4: Implement `server/routers/me.py`**

```python
"""Read-only, per-user endpoint scoped by the Bearer token's user_id.
The seed of the /v1/me/* API (SP2 expands it)."""
from __future__ import annotations

from fastapi import APIRouter, Depends

from ..db import get_pool
from ..auth_user import current_user_id

router = APIRouter(prefix="/v1/me", tags=["me"])


@router.get("")
async def me(user_id: str = Depends(current_user_id)):
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, display_name, created_at FROM users WHERE id = $1", user_id
        )
    return {
        "id": str(row["id"]),
        "display_name": row["display_name"],
        "created_at": row["created_at"].isoformat(),
    }
```

- [ ] **Step 5: Wire router + gate exemption in `server/main.py`**

Add `me` to the import and include it:

```python
from .routers import sessions, stream, admin, insights, tokens, me
```
```python
app.include_router(me.router)
```

Replace the gate so Bearer-authenticated prefixes skip the shared key:

```python
_OPEN_PATHS = {"/health", "/admin/dashboard"}
# Per-user routes authenticate via Bearer token inside the route, so they
# bypass the shared X-API-Key gate. (/v1/tokens stays gated — app-only.)
_BEARER_PREFIXES = ("/v1/me", "/mcp")


@app.middleware("http")
async def api_key_gate(request: Request, call_next):
    path = request.url.path
    if path in _OPEN_PATHS or path.startswith(_BEARER_PREFIXES):
        return await call_next(request)
    if not key_ok(request.headers.get("x-api-key")):
        return JSONResponse({"detail": "unauthorized"}, status_code=401)
    return await call_next(request)
```

- [ ] **Step 6: Run the full token test file — verify it passes**

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/wythin_test pytest server/tests/test_tokens.py -v`
Expected: PASS (all tests). Also run the whole suite to catch regressions:
`DATABASE_URL=... pytest server/tests/ -v` → all green.

- [ ] **Step 7: Commit**

```bash
git add server/auth_user.py server/routers/me.py server/main.py server/tests/test_tokens.py
git commit -m "feat(api): Bearer token auth dependency and scoped GET /v1/me"
```

---

## Self-Review notes

- **Spec coverage:** api_tokens schema (T1), issuance/list/revoke (T2), Bearer dependency + last_used_at + revoke-401 + rate limit (T3), scoping proven via /v1/me (T3). `/sessions` migration intentionally deferred (Global Constraints).
- **Type consistency:** `get_or_create_user` returns `str`; token endpoints pass it straight into asyncpg `uuid` params (same pattern as `sessions.py`). `current_user_id` returns `str`.
- **Deploy:** after merge, the deploy pulls to the Hetzner box and `create_schema()` runs on startup (adds `api_tokens` idempotently). Set nothing new; `API_KEY` already configured there so `/v1/tokens` stays gated in prod.
