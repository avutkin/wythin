from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app


@asynccontextmanager
async def _client():
    from server.db import init_pool, close_pool, create_schema
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


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


@pytest.mark.asyncio
async def test_tool_helpers_scope_to_user():
    from server.db import get_or_create_user, get_pool
    from server.mcp_server import (
        _list_sessions, _get_session, _get_session_samples, _whoami,
    )
    from server.db import init_pool, close_pool, create_schema
    await init_pool()
    await create_schema()
    try:
        # Unique device ids per run: the test DB persists between runs and
        # activities have no idempotency key, so fresh users keep this isolated.
        import uuid as _uuid
        sfx = _uuid.uuid4().hex[:8]
        uid_a = await get_or_create_user(f"mcp-scope-A-{sfx}")
        uid_b = await get_or_create_user(f"mcp-scope-B-{sfx}")
        async with get_pool().acquire() as conn:
            # A "session" is a logged activity; its samples are the user's
            # metric_samples within the activity window.
            sid = await conn.fetchval(
                "INSERT INTO activities (user_id, activity_type, started_at, ended_at, during_rsa) "
                "VALUES ($1, 'breathing', NOW() - interval '5 min', NOW(), 30) RETURNING id", uid_a)
            await conn.execute(
                "INSERT INTO metric_samples (user_id, ts, mean_bpm, rmssd) "
                "VALUES ($1, NOW() - interval '1 min', 62, 40) ON CONFLICT DO NOTHING", uid_a)

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
    finally:
        await close_pool()


@pytest.mark.asyncio
async def test_mcp_tools_registered_and_mounted():
    from server.mcp_server import mcp
    tools = {t.name for t in await mcp.list_tools()}
    assert {"whoami", "list_sessions", "get_session", "get_session_samples",
            "get_day_summary", "get_metric_trend", "get_metric_stats"} <= tools
    assert any(getattr(r, "path", "") == "/mcp" for r in app.routes)


@pytest.mark.asyncio
async def test_mcp_transport_requires_bearer():
    """The /mcp mount is gated at the transport: anonymous and bad-token callers
    get a real 401 before reaching FastMCP, so initialize/tools/list are not
    readable without a valid personal token."""
    async with _client() as c:
        body = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
        # Anonymous → 401 (previously reached tools/list unauthenticated).
        r = await c.post("/mcp/", json=body)
        assert r.status_code == 401
        # Malformed token → 401.
        r = await c.post("/mcp/", json=body,
                         headers={"Authorization": "Bearer not-a-wyth-token"})
        assert r.status_code == 401
        # (The valid-token path reaches FastMCP, whose session manager requires
        # the app lifespan; its reachability is covered by the mount test and the
        # live server. Here we assert only that the transport gate rejects
        # unauthenticated callers — the security fix.)


@pytest.mark.asyncio
async def test_metric_tools_scope_and_aggregate():
    from server.db import get_or_create_user, get_pool
    from server.mcp_server import _day_summary, _metric_trend, _metric_stats, _parse_dt
    import server.db as _  # ensure module import
    from server.db import init_pool, close_pool, create_schema
    await init_pool(); await create_schema()
    try:
        a = await get_or_create_user("mt-A"); b = await get_or_create_user("mt-B")
        async with get_pool().acquire() as conn:
            for i, pip in enumerate([40, 30, 20]):
                await conn.execute(
                    "INSERT INTO metric_samples (user_id, ts, pip, mean_bpm) VALUES ($1,$2,$3,$4) "
                    "ON CONFLICT DO NOTHING",
                    a, _parse_dt(f"2026-07-27T10:0{i}:00Z"), float(pip), 60.0)
        summ = await _day_summary(a, "2026-07-27")
        assert summ["pip"]["min"] == 20 and summ["pip"]["max"] == 40 and summ["pip"]["n"] == 3
        # user B sees nothing
        summ_b = await _day_summary(b, "2026-07-27")
        assert summ_b == {} or summ_b.get("pip", {}).get("n", 0) == 0
        stats = await _metric_stats(a, "inner_noise", "2026-07-27T00:00:00Z", "2026-07-28T00:00:00Z")
        assert stats["n"] == 3 and stats["min"] == 20
        trend = await _metric_trend(a, "pip", "2026-07-27T10:00:00Z", "2026-07-27T10:03:00Z", buckets=3)
        assert len(trend) >= 1
    finally:
        await close_pool()


def test_resolve_metric_alias_and_reject():
    from server.mcp_server import _resolve_metric
    assert _resolve_metric("inner_noise") == "pip"
    assert _resolve_metric("pip") == "pip"
    with pytest.raises(ValueError):
        _resolve_metric("; DROP TABLE")
