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

_TERMS_RECEIPT = {
    "version": "terms-v1-2026-11-15",
    "document_sha256": "a" * 64,
    "accepted_at": "2026-11-15T12:00:00Z",
}


@pytest.mark.asyncio
async def test_terms_receipt_is_append_only_and_never_grants_data_consent():
    from server.db import get_pool, get_or_create_user
    async with _client() as c:
        headers = {"X-User-ID": "terms-receipt-test"}
        uid = await get_or_create_user(headers["X-User-ID"])
        r = await c.post("/v1/profile", json={**_PROFILE, "terms_receipt": _TERMS_RECEIPT}, headers=headers)
        assert r.status_code == 200
        assert r.json()["terms_receipt_saved"] is True
        async with get_pool().acquire() as conn:
            first = await conn.fetchrow("SELECT * FROM terms_acceptances WHERE user_id=$1", uid)
            assert first["document_sha256"] == _TERMS_RECEIPT["document_sha256"]
            assert not await conn.fetchval("SELECT consent_ai_insights FROM profiles WHERE user_id=$1", uid)
            assert not await conn.fetchval("SELECT consent_share_team FROM profiles WHERE user_id=$1", uid)
        # A retry cannot rewrite the timestamp. Old clients cannot erase it.
        await c.post("/v1/profile", json={**_PROFILE, "terms_receipt": {
            **_TERMS_RECEIPT, "accepted_at": "2026-11-15T13:00:00Z"}}, headers=headers)
        await c.post("/v1/profile", json=_PROFILE, headers=headers)
        async with get_pool().acquire() as conn:
            rows = await conn.fetch("SELECT * FROM terms_acceptances WHERE user_id=$1", uid)
            assert len(rows) == 1
            assert rows[0]["accepted_at"] == first["accepted_at"]
            assert rows[0]["recorded_at"] == first["recorded_at"]


@pytest.mark.asyncio
@pytest.mark.parametrize("change", [
    {"document_sha256": "not-a-hash"}, {"version": ""},
    {"accepted_at": "not-a-date"}, {"accepted_at": "2026-11-15T12:00:00"},
])
async def test_profile_rejects_invalid_terms_receipt(change):
    async with _client() as c:
        r = await c.post("/v1/profile", json={**_PROFILE,
            "terms_receipt": {**_TERMS_RECEIPT, **change}}, headers={"X-User-ID": "terms-invalid"})
        assert r.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize("client_time", ["2099-01-01T00:00:00Z", "2020-01-01T00:00:00Z"])
async def test_skewed_client_clock_does_not_block_profile_or_permission_changes(client_time):
    from server.db import get_pool, get_or_create_user
    async with _client() as c:
        headers = {"X-User-ID": "terms-clock-" + client_time[:4]}
        r = await c.post("/v1/profile", json={**_PROFILE, "consent_ai_insights": False,
            "terms_receipt": {**_TERMS_RECEIPT, "accepted_at": client_time}}, headers=headers)
        assert r.status_code == 200
        uid = await get_or_create_user(headers["X-User-ID"])
        async with get_pool().acquire() as conn:
            receipt = await conn.fetchrow("SELECT * FROM terms_acceptances WHERE user_id=$1", uid)
            assert receipt["client_clock_suspect"] is True
            assert receipt["recorded_at"] != receipt["accepted_at"]
            assert not await conn.fetchval("SELECT consent_ai_insights FROM profiles WHERE user_id=$1", uid)


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


@pytest.mark.asyncio
async def test_profile_carries_the_phones_time_zone():
    """The phone reports its IANA zone with the profile; the admin user page
    reads it back so the dashboard can show that person's day in their own
    clock. A zone the server does not recognise is stored as unknown, never as
    a string the page would then hand to Intl and crash on."""
    async with _client() as c:
        r = await c.post("/v1/profile", json={**_PROFILE, "timezone": "Europe/Berlin"},
                         headers={"X-User-ID": "prof-tz"})
        assert r.status_code == 200
        stats = (await c.get("/admin/stats", params={"range": "all"})).json()
        me = next(u for u in stats["users"] if u["device_id"] == "prof-tz")
        assert me["timezone"] == "Europe/Berlin"
        det = (await c.get(f"/admin/users/{me['id']}")).json()
        assert det["user"]["timezone"] == "Europe/Berlin"
        assert det["profile"]["timezone"] == "Europe/Berlin"

        r = await c.post("/v1/profile", json={**_PROFILE, "timezone": "Mars/Olympus"},
                         headers={"X-User-ID": "prof-tz"})
        assert r.status_code == 200
        det = (await c.get(f"/admin/users/{me['id']}")).json()
        assert det["user"]["timezone"] is None

        # An older app that sends no zone at all leaves it unknown.
        r = await c.post("/v1/profile", json=_PROFILE, headers={"X-User-ID": "prof-tz-old"})
        assert r.status_code == 200
        stats = (await c.get("/admin/stats", params={"range": "all"})).json()
        old = next(u for u in stats["users"] if u["device_id"] == "prof-tz-old")
        assert old["timezone"] is None
