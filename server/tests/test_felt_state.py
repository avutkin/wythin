"""
Self check-in ingest. The phone posts one FeltStateLog at a time to
POST /felt-state-logs (the client half shipped in August, the server half
did not). Requires PostgreSQL (set DATABASE_URL), like the other DB tests.
"""
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
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            yield client
    finally:
        await close_pool()


_MOMENT = {
    "id":           "aaaaaaaa-0000-0000-0000-000000000001",
    "kind":         "moment",
    "timestamp":    "2026-09-13T14:37:00Z",
    "day_key":      "2026-09-13",
    "timezone":     "America/Los_Angeles",
    "mood":         71.0,
    "focus":        40.0,
    "energy":       55.5,
    "anxiety":      None,          # untouched stays null, never 50
    "stress":       20.0,
    "worn_minutes": 13.2,
}

# Exactly what the August build sends: five keys and a state key, no kind.
_LEGACY = {
    "id":        "aaaaaaaa-0000-0000-0000-000000000002",
    "timestamp": "2026-08-03T10:00:00Z",
    "focus":     60.0,
    "energy":    None,
    "stress":    30.0,
    "mood":      80.0,
    "state_key": "sharp",
}


async def _rows(device_id: str):
    from server.db import get_pool
    async with get_pool().acquire() as conn:
        return await conn.fetch(
            "SELECT f.* FROM felt_state_logs f JOIN users u ON u.id = f.user_id "
            "WHERE u.device_id = $1 ORDER BY f.ts",
            device_id,
        )


@pytest.mark.asyncio
async def test_moment_round_trip_and_upsert():
    async with _client() as c:
        r = await c.post("/felt-state-logs", json=_MOMENT, headers={"X-User-ID": "felt-user-1"})
        assert r.status_code == 200, r.text
        assert r.json()["id"]

        # A re-send with a changed mood updates the row instead of adding one.
        again = dict(_MOMENT, mood=90.0)
        r2 = await c.post("/felt-state-logs", json=again, headers={"X-User-ID": "felt-user-1"})
        assert r2.status_code == 200, r2.text

        rows = await _rows("felt-user-1")
        assert len(rows) == 1
        row = rows[0]
        assert row["kind"] == "moment"
        assert row["mood"] == 90.0
        assert row["anxiety"] is None
        assert row["day_key"] == "2026-09-13"
        assert row["timezone"] == "America/Los_Angeles"
        assert abs(row["worn_minutes"] - 13.2) < 1e-6


@pytest.mark.asyncio
async def test_resend_without_a_scale_keeps_the_stored_value():
    """An older client omits keys it does not know. Absence must not clear a
    value a newer build already stored — the same rule activities use."""
    async with _client() as c:
        full = dict(_MOMENT, id="aaaaaaaa-0000-0000-0000-000000000022")
        await c.post("/felt-state-logs", json=full, headers={"X-User-ID": "felt-user-2"})
        trimmed = {k: v for k, v in full.items() if k not in ("stress", "worn_minutes", "day_key")}
        r = await c.post("/felt-state-logs", json=trimmed, headers={"X-User-ID": "felt-user-2"})
        assert r.status_code == 200, r.text
        row = (await _rows("felt-user-2"))[0]
        assert row["stress"] == 20.0
        assert row["day_key"] == "2026-09-13"


@pytest.mark.asyncio
async def test_legacy_body_is_a_moment():
    async with _client() as c:
        r = await c.post("/felt-state-logs", json=_LEGACY, headers={"X-User-ID": "felt-user-3"})
        assert r.status_code == 200, r.text
        row = (await _rows("felt-user-3"))[0]
        assert row["kind"] == "moment"
        assert row["state_key"] == "sharp"
        assert row["energy"] is None
        assert row["anxiety"] is None and row["sleep"] is None


@pytest.mark.asyncio
async def test_unknown_zone_is_stored_as_null():
    async with _client() as c:
        r = await c.post("/felt-state-logs", json=dict(_MOMENT, id="aaaaaaaa-0000-0000-0000-000000000044", timezone="Mars/Olympus"),
                         headers={"X-User-ID": "felt-user-4"})
        assert r.status_code == 200, r.text
        assert (await _rows("felt-user-4"))[0]["timezone"] is None


@pytest.mark.asyncio
async def test_admin_user_page_lists_check_ins_newest_first():
    prev = dict(_MOMENT, id="aaaaaaaa-0000-0000-0000-000000000005", kind="previous_day",
                timestamp="2026-09-14T08:02:00Z", day_key="2026-09-13",
                mood=None, sleep=35.0, worn_minutes=None)
    async with _client() as c:
        await c.post("/felt-state-logs", json=dict(_MOMENT, id="aaaaaaaa-0000-0000-0000-000000000055"), headers={"X-User-ID": "felt-user-5"})
        await c.post("/felt-state-logs", json=prev, headers={"X-User-ID": "felt-user-5"})
        # A user with check-ins but no strap data is not in /admin/stats yet,
        # so look the id up directly.
        from server.db import get_pool
        async with get_pool().acquire() as conn:
            uid = await conn.fetchval("SELECT id FROM users WHERE device_id = 'felt-user-5'")
        d = (await c.get(f"/admin/users/{uid}")).json()
        cis = d["check_ins"]
        assert [x["kind"] for x in cis] == ["previous_day", "moment"]
        assert set(cis[0]) >= {"kind", "ts", "day_key", "timezone", "focus", "energy",
                               "stress", "mood", "anxiety", "sleep", "state_key", "worn_minutes"}
        assert cis[0]["sleep"] == 35.0 and cis[0]["mood"] is None
        assert cis[0]["ts"].startswith("2026-09-14T08:02:00")


@pytest.mark.asyncio
async def test_delete_my_data_removes_check_ins():
    async with _client() as c:
        await c.post("/felt-state-logs", json=dict(_MOMENT, id="aaaaaaaa-0000-0000-0000-000000000066"), headers={"X-User-ID": "felt-del"})
        tok = (await c.post("/v1/tokens", json={"name": "t"},
                            headers={"X-User-ID": "felt-del"})).json()["token"]
        r = await c.delete("/v1/me/data", headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 200
        assert r.json()["felt_state_logs"] >= 1
        assert await _rows("felt-del") == []
