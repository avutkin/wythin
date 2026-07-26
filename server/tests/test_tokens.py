from __future__ import annotations

from contextlib import asynccontextmanager
import pytest
from asgi_lifespan import LifespanManager
from httpx import AsyncClient, ASGITransport
from server.main import app

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
