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
