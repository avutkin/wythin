"""
Admin dashboard + stats tests.

`test_dashboard_shell_open` needs no database — it exercises only the middleware
gate and the static HTML shell. `test_stats_shape` requires PostgreSQL (like the
other server tests); set DATABASE_URL to run it.
"""
from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app


@asynccontextmanager
async def _client():
    # Init the DB pool directly rather than driving the app lifespan, which runs
    # the single-shot MCP session manager and cannot be re-entered per test.
    from server.db import init_pool, close_pool, create_schema
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            yield client
    finally:
        await close_pool()


@pytest.mark.asyncio
async def test_dashboard_shell_open_but_stats_gated(monkeypatch):
    """With a key configured, the data-free shell is still reachable, but the
    data endpoints demand the key. No DB needed — the gate rejects before the
    route runs, and the shell touches no pool."""
    monkeypatch.setattr("server.auth.API_KEY", "secret")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        shell = await client.get("/admin/dashboard")
        assert shell.status_code == 200
        assert "text/html" in shell.headers["content-type"]
        assert "User Activity" in shell.text

        for path in ("/admin/stats",
                     "/admin/users/00000000-0000-0000-0000-000000000000",
                     "/admin/sessions/00000000-0000-0000-0000-000000000000/samples"):
            r = await client.get(path)
            assert r.status_code == 401, path
        # The success paths (correct key → data) need a DB and are covered by
        # test_stats_shape / test_user_and_session_drilldown.


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
        "total_sessions", "total_minutes", "avg_session_min", "median_streak",
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

    u = next(x for x in data["users"] if x["session_count"] >= 1)
    assert "current_streak" in u
    assert "days_active_7d" in u
    assert "practiced_today" in u
    assert isinstance(u["current_streak"], int)


@pytest.mark.asyncio
async def test_user_and_session_drilldown():
    """Upload a session, then drill: /admin/users/{id} lists it, and
    /admin/sessions/{id}/samples returns its time series. Requires a database."""
    payload = {
        "id":            "00000000-0000-0000-0000-0000000000b2",
        "started_at":    "2025-03-01T08:00:00Z",
        "ended_at":      "2025-03-01T08:08:00Z",
        "avg_rsa_ms":    27.0,
        "avg_coherence": 0.61,
        "samples": [
            {"ts": "2025-03-01T08:00:02Z", "mean_bpm": 61.0, "rmssd": 38.0, "coherence": 0.6, "breath_bpm": 6.0},
            {"ts": "2025-03-01T08:00:04Z", "mean_bpm": 60.0, "rmssd": 42.0, "coherence": 0.7, "breath_bpm": 5.8},
        ],
    }
    async with _client() as client:
        up = await client.post("/sessions", json=payload, headers={"X-User-ID": "test-drill-user"})
        assert up.status_code == 200

        stats = (await client.get("/admin/stats", params={"days": 3650})).json()
        me = next(u for u in stats["users"] if u["device_id"] == "test-drill-user")

        det = await client.get(f"/admin/users/{me['id']}")
        assert det.status_code == 200
        dd = det.json()
        assert dd["user"]["id"] == me["id"]
        assert dd["sessions"], "expected the uploaded session"
        sess = dd["sessions"][0]
        assert set(sess) >= {
            "id", "started_at", "ended_at", "duration_min",
            "avg_rsa_ms", "avg_coherence", "best_resonance_bpm", "sample_count",
        }

        samples = await client.get(f"/admin/sessions/{sess['id']}/samples")
        assert samples.status_code == 200
        sd = samples.json()
        assert len(sd["samples"]) >= 1
        assert set(sd["samples"][0]) >= {
            "ts", "mean_bpm", "rmssd", "sdnn", "rsa_ms", "coherence", "breath_bpm", "lf_hf",
        }

    # A missing user is a clean 404.
    async with _client() as client:
        nf = await client.get("/admin/users/00000000-0000-0000-0000-0000000000ff")
        assert nf.status_code == 404
