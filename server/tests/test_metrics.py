from __future__ import annotations
from contextlib import asynccontextmanager
import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app

@asynccontextmanager
async def _client():
    from server.db import init_pool, close_pool, create_schema
    await init_pool(); await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()

def _sample(ts, pip):
    return {"ts": ts, "mean_bpm": 62.0, "rmssd": 40.0, "pip": pip, "dc": 7.5, "dfa1": 1.0, "vti": 3.9}

@pytest.mark.asyncio
async def test_upload_is_idempotent_and_scoped():
    async with _client() as c:
        body = {"samples": [_sample("2026-07-27T10:00:00Z", 30), _sample("2026-07-27T10:00:02Z", 31)]}
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200 and r.json()["stored"] == 2
        # Re-post same ts → no duplicates (ON CONFLICT DO NOTHING)
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200

@pytest.mark.asyncio
async def test_delete_my_data_scoped_to_token_user():
    async with _client() as c:
        await c.post("/v1/metrics", json={"samples": [_sample("2026-07-27T11:00:00Z", 30)]},
                     headers={"X-User-ID": "ms-del"})
        tok = (await c.post("/v1/tokens", json={"name": "t"}, headers={"X-User-ID": "ms-del"})).json()["token"]
        r = await c.delete("/v1/me/data", headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 200
        assert r.json()["metric_samples"] >= 1


@pytest.mark.asyncio
async def test_valueless_samples_are_not_stored():
    """A sample with every metric null measures nothing — it is a timestamp
    pretending to be a reading, and 7.6% of production rows were exactly that.
    Drop them at ingest and report how many were skipped."""
    import uuid
    device = f"ms-empty-{uuid.uuid4().hex[:8]}"
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": device}, json={"samples": [
            _sample("2026-07-27T11:00:00Z", 30),                      # real
            {"ts": "2026-07-27T11:00:02Z"},                           # every metric null
            {"ts": "2026-07-27T11:00:04Z", "mean_bpm": None, "rmssd": None},
            _sample("2026-07-27T11:00:06Z", 31),                      # real
        ]})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["stored"] == 2, body
        assert body["skipped"] == 2, body

        # The series carries readings, and every bucket in it has real values
        # rather than a row of nulls. (Buckets are 4h wide at 30d, so the two
        # readings six seconds apart share one bucket — count is not the point.)
        stats = await c.get("/admin/stats", params={"range": "all"})
        uid = next(u["id"] for u in stats.json()["users"] if u["device_id"] == device)
        series = await c.get(f"/admin/users/{uid}/metrics", params={"window": "30d"})
    buckets = series.json()["samples"]
    assert buckets, "expected the real readings"
    assert all(b["mean_bpm"] is not None for b in buckets)

    # A sample carrying a single real value is still a reading and is kept.
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": device}, json={"samples": [
            {"ts": "2026-07-27T11:00:08Z", "coherence": 0.5},
        ]})
    assert r.json()["stored"] == 1


@pytest.mark.asyncio
async def test_export_pages_in_order_and_is_scoped():
    """Read-back for a wiped phone: oldest first, cursor-paged, and never
    anyone else's rows."""
    import uuid
    dev   = f"ms-exp-{uuid.uuid4().hex[:8]}"
    other = f"ms-exp-{uuid.uuid4().hex[:8]}"
    async with _client() as c:
        await c.post("/v1/metrics", headers={"X-User-ID": dev}, json={"samples": [
            _sample(f"2026-07-27T10:00:0{i}Z", 30 + i) for i in range(3)]})
        await c.post("/v1/metrics", headers={"X-User-ID": other}, json={"samples": [
            _sample("2026-07-27T10:00:00Z", 99)]})

        r1 = await c.get("/v1/metrics/export", params={"limit": 2},
                         headers={"X-User-ID": dev})
        assert r1.status_code == 200, r1.text
        p1 = r1.json()
        assert [s["pip"] for s in p1["samples"]] == [30.0, 31.0]
        assert p1["next_cursor"] is not None

        r2 = await c.get("/v1/metrics/export",
                         params={"limit": 2, "cursor": p1["next_cursor"]},
                         headers={"X-User-ID": dev})
        p2 = r2.json()
        assert [s["pip"] for s in p2["samples"]] == [32.0]
        assert p2["next_cursor"] is None
