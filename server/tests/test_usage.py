"""
Usage-telemetry ingest tests. Requires PostgreSQL (set DATABASE_URL), like the
other DB-backed server tests.
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


_EVENTS = {
    "events": [
        {"client_event_id": "11111111-1111-1111-1111-111111111111",
         "event_type": "foreground", "ts": "2026-07-28T10:00:00Z", "duration_ms": 45000},
        {"client_event_id": "22222222-2222-2222-2222-222222222222",
         "event_type": "ecg_recording", "ts": "2026-07-28T10:05:00Z", "duration_ms": 600000},
    ]
}


@pytest.mark.asyncio
async def test_usage_ingest_and_idempotent():
    from server.db import get_pool
    async with _client() as client:
        r1 = await client.post("/v1/usage", headers={"X-User-ID": "test-usage-user"}, json=_EVENTS)
        assert r1.status_code == 200, r1.text
        assert r1.json()["received"] == 2

        # Re-upload the same events — must not duplicate (idempotent on client_event_id).
        r2 = await client.post("/v1/usage", headers={"X-User-ID": "test-usage-user"}, json=_EVENTS)
        assert r2.status_code == 200

        pool = get_pool()
        async with pool.acquire() as conn:
            n = await conn.fetchval(
                "SELECT count(*) FROM usage_events ue JOIN users u ON u.id = ue.user_id "
                "WHERE u.device_id = 'test-usage-user'"
            )
        assert n == 2, f"expected 2 events after double upload, got {n}"


@pytest.mark.asyncio
async def test_usage_empty_batch_ok():
    async with _client() as client:
        r = await client.post("/v1/usage", headers={"X-User-ID": "test-usage-user2"}, json={"events": []})
        assert r.status_code == 200
        assert r.json()["received"] == 0
