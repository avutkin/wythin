"""
Activity upload + dashboard exposure tests. Require PostgreSQL (set DATABASE_URL).
"""
from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
from asgi_lifespan import LifespanManager
from httpx import AsyncClient, ASGITransport
from server.main import app


@asynccontextmanager
async def _client():
    async with LifespanManager(app) as manager:
        async with AsyncClient(transport=ASGITransport(app=manager.app), base_url="http://test") as client:
            yield client


_PAYLOAD = {
    "id":               "00000000-0000-0000-0000-0000000000c3",
    "activity_type":    "Meditation",
    "activity_subtype": "Body Scan",
    "started_at":       "2025-04-01T07:00:00Z",
    "ended_at":         "2025-04-01T07:15:00Z",
    "is_manual":        False,
    "impact_score":     72,
    "before_rmssd":     40.0, "during_rmssd": 52.0, "after_rmssd": 48.0,
    "before_hr":        64.0, "during_hr":    60.0, "after_hr":    62.0,
}


async def _user_activities(client, device_id):
    stats = (await client.get("/admin/stats", params={"days": 3650})).json()
    me = next(u for u in stats["users"] if u["device_id"] == device_id)
    det = (await client.get(f"/admin/users/{me['id']}")).json()
    return det["activities"]


@pytest.mark.asyncio
async def test_activity_upload_appears_in_user_detail():
    async with _client() as client:
        up = await client.post("/activities", json=_PAYLOAD, headers={"X-User-ID": "test-activity-user"})
        assert up.status_code == 200
        assert "id" in up.json()

        acts = await _user_activities(client, "test-activity-user")
        mine = [a for a in acts if a["id"] == _PAYLOAD["id"]]
        assert mine, "uploaded activity should appear in user detail"
        a = mine[0]
        assert a["activity_type"] == "Meditation"
        assert a["activity_subtype"] == "Body Scan"
        assert a["impact_score"] == 72
        assert a["during_rmssd"] == 52.0
        assert a["before_hr"] == 64.0


@pytest.mark.asyncio
async def test_activity_upload_is_idempotent():
    async with _client() as client:
        await client.post("/activities", json=_PAYLOAD, headers={"X-User-ID": "test-activity-user"})
        await client.post("/activities", json=_PAYLOAD, headers={"X-User-ID": "test-activity-user"})
        acts = await _user_activities(client, "test-activity-user")
        assert len([a for a in acts if a["id"] == _PAYLOAD["id"]]) == 1
