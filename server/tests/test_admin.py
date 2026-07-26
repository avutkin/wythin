"""
Admin dashboard + stats tests.

`test_dashboard_shell_open` needs no database — it exercises only the middleware
gate and the static HTML shell. `test_stats_shape` requires PostgreSQL (like the
other server tests); set DATABASE_URL to run it.
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


@pytest.mark.asyncio
async def test_dashboard_shell_open_but_stats_gated(monkeypatch):
    """With a key configured, the data-free shell is still reachable, but the
    data endpoint demands the key. No DB needed — the gate rejects before the
    route runs, and the shell touches no pool."""
    monkeypatch.setattr("server.auth.API_KEY", "secret")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        shell = await client.get("/admin/dashboard")
        assert shell.status_code == 200
        assert "text/html" in shell.headers["content-type"]
        assert "User Activity" in shell.text

        blocked = await client.get("/admin/stats")
        assert blocked.status_code == 401
        # The success path (correct key → data) needs a DB and is covered by
        # test_stats_shape.


@pytest.mark.asyncio
async def test_stats_shape():
    """Upload a session, then confirm /admin/stats returns the expected shape
    and reflects the new data. Requires a live database."""
    payload = {
        "id":            "00000000-0000-0000-0000-0000000000a1",
        "started_at":    "2025-02-01T09:00:00Z",
        "ended_at":      "2025-02-01T09:12:00Z",
        "avg_rsa_ms":    30.0,
        "avg_coherence": 0.66,
        "samples": [
            {"ts": "2025-02-01T09:00:02Z", "mean_bpm": 60.0, "rmssd": 40.0, "coherence": 0.7},
        ],
    }
    async with _client() as client:
        up = await client.post("/sessions", json=payload, headers={"X-User-ID": "test-stats-user"})
        assert up.status_code == 200

        r = await client.get("/admin/stats", params={"days": 3650})
    assert r.status_code == 200
    data = r.json()

    assert set(data["kpis"]) == {
        "total_users", "active_7d", "active_30d",
        "total_sessions", "total_minutes", "avg_session_min",
    }
    assert data["kpis"]["total_users"] >= 1
    assert data["kpis"]["total_sessions"] >= 1
    assert isinstance(data["sessions_per_day"], list)
    assert isinstance(data["users"], list)
    assert data["users"], "expected at least one user row"

    row = data["users"][0]
    assert set(row) >= {
        "id", "device_id", "display_name", "first_seen", "last_seen",
        "session_count", "total_minutes", "avg_coherence", "avg_rsa",
    }
