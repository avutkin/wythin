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


@pytest.mark.asyncio
async def test_user_metrics_series():
    """Upload recent per-user metric_samples, then confirm the bucketed live
    series endpoint returns them (incl. advanced columns). Requires a database."""
    from datetime import datetime, timezone, timedelta
    base = datetime.now(timezone.utc) - timedelta(minutes=5)
    async with _client() as client:
        up = await client.post("/v1/metrics", headers={"X-User-ID": "test-metrics-user"}, json={
            "samples": [
                {"ts": base.isoformat(),                         "mean_bpm": 61.0, "rmssd": 42.0, "coherence": 0.60, "dc": 6.0, "dfa1": 1.0},
                {"ts": (base + timedelta(seconds=2)).isoformat(), "mean_bpm": 62.0, "rmssd": 44.0, "coherence": 0.62, "dc": 6.5, "dfa1": 1.05},
            ]
        })
        assert up.status_code in (200, 201), up.text

        stats = await client.get("/admin/stats", params={"days": 3650})
        uid = next(u["id"] for u in stats.json()["users"] if u["device_id"] == "test-metrics-user")

        r = await client.get(f"/admin/users/{uid}/metrics", params={"window": "24h"})
    assert r.status_code == 200
    body = r.json()
    assert body["window"] == "24h"
    assert isinstance(body["samples"], list) and body["samples"], "expected bucketed samples"
    assert {"ts", "mean_bpm", "rmssd", "coherence", "dc", "dfa1"} <= set(body["samples"][0])


@pytest.mark.asyncio
async def test_activity_detail():
    """Upload an activity, then fetch its before/during/after detail by SERVER id
    (the upload returns the server id, distinct from the client id)."""
    act = {
        "id":               "00000000-0000-0000-0000-0000000000b1",
        "activity_type":    "Meditation",
        "activity_subtype": "Vipassana",
        "started_at":       "2025-04-01T08:00:00Z",
        "ended_at":         "2025-04-01T08:12:00Z",
        "impact_score":     62,
        "before_rsa": 20.0, "during_rsa": 30.0, "after_rsa": 26.0,
    }
    async with _client() as client:
        up = await client.post("/activities", headers={"X-User-ID": "test-act-user"}, json=act)
        assert up.status_code == 200, up.text
        sid = up.json()["id"]
        r = await client.get(f"/admin/activities/{sid}")
    assert r.status_code == 200
    d = r.json()
    assert d["activity_subtype"] == "Vipassana"
    assert d["impact_score"] == 62
    assert d["during_rsa"] == 30.0 and d["before_rsa"] == 20.0

    # A missing activity is a clean 404.
    async with _client() as client:
        nf = await client.get("/admin/activities/00000000-0000-0000-0000-0000000000fe")
        assert nf.status_code == 404


@pytest.mark.asyncio
async def test_user_usage_aggregation():
    """Upload usage events, then confirm the per-user usage aggregation
    endpoint and the /admin/stats per-user usage averages."""
    from datetime import datetime, timezone, timedelta
    import uuid
    # Isolated per run: fixed ids + a fixed device would keep the first run's
    # timestamps alive across runs (the usage endpoint dedupes on client_event_id).
    # Anchor to a fixed midday-UTC on a past day so the two foreground events share
    # one UTC day and never straddle midnight — day bucketing is UTC (see init_pool).
    sfx = uuid.uuid4().hex[:8]
    device = f"test-usage-agg-{sfx}"
    base = (datetime.now(timezone.utc) - timedelta(days=1)).replace(
        hour=12, minute=0, second=0, microsecond=0)
    async with _client() as client:
        up = await client.post("/v1/usage", headers={"X-User-ID": device}, json={"events": [
            {"client_event_id": str(uuid.uuid4()), "event_type": "foreground",    "ts": base.isoformat(),                         "duration_ms": 120000},
            {"client_event_id": str(uuid.uuid4()), "event_type": "foreground",    "ts": (base + timedelta(minutes=30)).isoformat(), "duration_ms": 60000},
            {"client_event_id": str(uuid.uuid4()), "event_type": "ecg_recording", "ts": base.isoformat(),                         "duration_ms": 600000},
        ]})
        assert up.status_code == 200, up.text

        stats = await client.get("/admin/stats", params={"days": 3650})
        u = next(x for x in stats.json()["users"] if x["device_id"] == device)
        assert {"avg_opens_day", "avg_active_min_day", "avg_ecg_day"} <= set(u)

        r = await client.get(f"/admin/users/{u['id']}/usage", params={"days": 30})
    assert r.status_code == 200
    d = r.json()
    assert d["series"], "expected a per-day row"
    row = d["series"][-1]
    assert row["opens"] == 2 and row["ecg_recordings"] == 1
    assert abs(row["active_min"] - 3.0) < 0.1   # 120s + 60s = 180s = 3.0 min
    assert abs(row["ecg_min"] - 10.0) < 0.1     # 600s = 10 min
    assert d["averages"]["opens_day"] >= 2
