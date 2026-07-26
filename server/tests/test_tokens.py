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


@pytest.mark.asyncio
async def test_gate_behavior_under_live_api_key(monkeypatch):
    """With API_KEY configured, /v1/tokens still requires the shared key
    (it is NOT a Bearer route), while /v1/me bypasses the shared key and
    is authenticated solely by the Bearer token. This is the regression
    guard for the _BEARER_PREFIXES gate carve-out: it must fail if /v1/me
    is ever re-coupled to the shared key, or /v1/tokens is accidentally
    exempted."""
    monkeypatch.setattr("server.auth.API_KEY", "secret")
    async with _client() as c:
        # /v1/tokens without X-API-Key → 401 (gate blocks it)
        r = await c.get("/v1/tokens", headers={"X-User-ID": "gate-device-1"})
        assert r.status_code == 401

        # Minting a token requires the shared key
        made = await c.post(
            "/v1/tokens",
            json={"name": "cc"},
            headers={"X-API-Key": "secret", "X-User-ID": "gate-device-1"},
        )
        assert made.status_code == 200
        token = made.json()["token"]

        # /v1/me with Bearer token and NO X-API-Key → 200 (gate bypassed
        # for this route; the Bearer dependency authenticates instead)
        r = await c.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 200
