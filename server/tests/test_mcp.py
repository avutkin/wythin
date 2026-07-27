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
