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


_PROFILE = {
    "phone": "+15551234567",
    "email": "a@example.com",
    "age_range": "25-34",
    "gender": "prefer_not",
    "goals": ["Reduce stress", "Sleep better"],
    "practices": ["Meditation", "Breathwork"],
    "devices": ["Polar H10"],
}


@pytest.mark.asyncio
async def test_profile_upsert_scoped_and_readable():
    from server.db import get_or_create_user
    from server.mcp_server import _profile
    async with _client() as c:
        r = await c.post("/v1/profile", json=_PROFILE, headers={"X-User-ID": "prof-A"})
        assert r.status_code == 200

        uid_a = await get_or_create_user("prof-A")
        got = await _profile(uid_a)
        assert got["goals"] == ["Reduce stress", "Sleep better"]
        assert got["practices"] == ["Meditation", "Breathwork"]
        assert got["email"] == "a@example.com"
        assert got["phone"] == "+15551234567"

        # whoami ("who I am") folds the profile in
        from server.mcp_server import _whoami
        who = await _whoami(uid_a)
        assert who["id"] == uid_a
        assert who["profile"]["goals"] == ["Reduce stress", "Sleep better"]

        # Upsert: a second POST updates in place (still one row)
        r = await c.post("/v1/profile", json={**_PROFILE, "goals": ["Focus"]},
                         headers={"X-User-ID": "prof-A"})
        assert r.status_code == 200
        assert (await _profile(uid_a))["goals"] == ["Focus"]

        # Cross-user isolation: B has no profile
        uid_b = await get_or_create_user("prof-B")
        assert await _profile(uid_b) == {}


@pytest.mark.asyncio
async def test_delete_my_data_removes_profile():
    async with _client() as c:
        await c.post("/v1/profile", json=_PROFILE, headers={"X-User-ID": "prof-del"})
        tok = (await c.post("/v1/tokens", json={"name": "t"},
                            headers={"X-User-ID": "prof-del"})).json()["token"]
        r = await c.delete("/v1/me/data", headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 200
        assert r.json()["profiles"] >= 1
