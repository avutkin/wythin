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
        # The page ships its own JS; a cached copy would run an old dashboard
        # against the current API and look like a failed deploy.
        assert "no-store" in shell.headers.get("cache-control", "")

        for path in ("/admin/stats",
                     "/admin/users/00000000-0000-0000-0000-000000000000",
                     "/admin/sessions/00000000-0000-0000-0000-000000000000/samples"):
            r = await client.get(path)
            assert r.status_code == 401, path
        # The success paths (correct key → data) need a DB and are covered by
        # test_stats_shape / test_user_and_session_drilldown.


@pytest.mark.asyncio
async def test_stats_shape():
    """Record a strap session, then confirm /admin/stats returns the expected
    shape and reflects the new data. Requires a live database."""
    from datetime import datetime, timezone, timedelta
    import uuid

    device = f"test-stats-{uuid.uuid4().hex[:8]}"
    async with _client() as client:
        up = await client.post("/v1/usage", headers={"X-User-ID": device}, json={"events": [
            {"client_event_id": str(uuid.uuid4()), "event_type": "ecg_recording",
             "ts": (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat(),
             "duration_ms": 720_000},
        ]})
        assert up.status_code == 200, up.text

        r = await client.get("/admin/stats", params={"range": "all"})
    assert r.status_code == 200
    data = r.json()

    assert set(data["kpis"]) == {
        "total_users", "active_users",
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


@pytest.mark.asyncio
async def test_sessions_are_strap_wear_over_one_minute():
    """A session is the strap being live for at least a minute — an
    `ecg_recording` usage event with duration_ms >= 60000. Shorter recordings
    and `foreground` events are not sessions, and the range picker scopes both
    the KPIs and the per-user rows. Requires a database."""
    from datetime import datetime, timezone, timedelta
    import uuid

    device = f"test-strap-{uuid.uuid4().hex[:8]}"
    now = datetime.now(timezone.utc)
    recent = now - timedelta(minutes=5)   # inside every range
    old = now - timedelta(days=10)        # inside 90d, outside 24h
    async with _client() as client:
        up = await client.post("/v1/usage", headers={"X-User-ID": device}, json={"events": [
            # 10 min of strap — a session.
            {"client_event_id": str(uuid.uuid4()), "event_type": "ecg_recording",
             "ts": recent.isoformat(), "duration_ms": 600_000},
            # 30 s of strap — under the one-minute bar, not a session.
            {"client_event_id": str(uuid.uuid4()), "event_type": "ecg_recording",
             "ts": recent.isoformat(), "duration_ms": 30_000},
            # 15 min of app in the foreground — not a session, not practice minutes.
            {"client_event_id": str(uuid.uuid4()), "event_type": "foreground",
             "ts": recent.isoformat(), "duration_ms": 900_000},
            # 6 min of strap ten days ago — a session, but only in the wider ranges.
            {"client_event_id": str(uuid.uuid4()), "event_type": "ecg_recording",
             "ts": old.isoformat(), "duration_ms": 360_000},
        ]})
        assert up.status_code == 200, up.text

        wide = (await client.get("/admin/stats", params={"range": "90d"})).json()
        day = (await client.get("/admin/stats", params={"range": "24h"})).json()
        today = await client.get("/admin/stats", params={"range": "today", "tz_offset": 0})

    # 90 days: both qualifying straps, 16 minutes. The 30 s strap and the
    # foreground event contribute nothing.
    me = next(u for u in wide["users"] if u["device_id"] == device)
    assert me["session_count"] == 2, me
    assert abs(me["total_minutes"] - 16.0) < 0.1, me

    # 24 hours: only the recent 10-minute strap.
    me24 = next(u for u in day["users"] if u["device_id"] == device)
    assert me24["session_count"] == 1, me24
    assert abs(me24["total_minutes"] - 10.0) < 0.1, me24

    k = day["kpis"]
    assert set(k) == {"total_users", "active_users", "total_sessions",
                      "total_minutes", "avg_session_min", "median_streak"}
    assert k["total_sessions"] >= 1 and k["active_users"] >= 1
    assert k["total_minutes"] >= 10.0
    assert k["avg_session_min"] > 0

    # Short ranges bucket the chart by hour, longer ones by day, and the recent
    # strap has to land in a bucket.
    assert day["bucket"] == "hour" and wide["bucket"] == "day"
    assert day["sessions_per_day"], "expected a bucket holding the recent strap"
    assert sum(p["sessions"] for p in day["sessions_per_day"]) >= 1
    assert today.status_code == 200


@pytest.mark.asyncio
async def test_stats_carries_onboarding_goals_and_practices():
    """The user table shows what each person is optimising for, so /admin/stats
    carries their onboarding goals and practices. Users who never completed
    onboarding come back as empty lists, not nulls. Requires a database."""
    from datetime import datetime, timezone, timedelta
    import uuid

    sfx = uuid.uuid4().hex[:8]
    with_profile, without = f"test-prof-{sfx}", f"test-noprof-{sfx}"
    goals = ["Reduce stress", "Sleep better", "Focus"]
    practices = ["Breathwork", "Meditation"]
    async with _client() as client:
        r = await client.post("/v1/profile", headers={"X-User-ID": with_profile}, json={
            "email": "someone@example.com", "age_range": "35-44",
            "goals": goals, "practices": practices, "devices": ["Polar H10"],
        })
        assert r.status_code == 200, r.text
        # Both users need a signal so the range filter keeps them.
        for device in (with_profile, without):
            u = await client.post("/v1/usage", headers={"X-User-ID": device}, json={"events": [
                {"client_event_id": str(uuid.uuid4()), "event_type": "foreground",
                 "ts": (datetime.now(timezone.utc) - timedelta(minutes=2)).isoformat(),
                 "duration_ms": 60_000},
            ]})
            assert u.status_code == 200, u.text

        data = (await client.get("/admin/stats", params={"range": "24h"})).json()

    row = next(u for u in data["users"] if u["device_id"] == with_profile)
    assert row["goals"] == goals
    assert row["practices"] == practices

    bare = next(u for u in data["users"] if u["device_id"] == without)
    assert bare["goals"] == [] and bare["practices"] == []


@pytest.mark.asyncio
async def test_user_detail_carries_full_onboarding_answers():
    """Clicking a user shows everything they answered at onboarding — contact
    details and every multi-select. Users who never onboarded return a null
    profile rather than a half-empty object. Requires a database."""
    import uuid

    sfx = uuid.uuid4().hex[:8]
    onboarded, bare = f"test-onb-{sfx}", f"test-bare-{sfx}"
    answers = {
        "phone": "+1 555 0100", "email": "someone@example.com",
        "age_range": "35-44", "gender": "Female",
        "goals": ["Improve sleep", "Sharpen focus"],
        "practices": ["Breathwork", "Yoga"],
        "devices": ["Oura Ring", "Just this app"],
    }
    async with _client() as client:
        r = await client.post("/v1/profile", headers={"X-User-ID": onboarded}, json=answers)
        assert r.status_code == 200, r.text
        r = await client.post("/v1/usage", headers={"X-User-ID": bare}, json={"events": [
            {"client_event_id": str(uuid.uuid4()), "event_type": "foreground",
             "ts": "2026-01-01T10:00:00Z", "duration_ms": 60_000},
        ]})
        assert r.status_code == 200, r.text

        stats = (await client.get("/admin/stats", params={"range": "all"})).json()
        ids = {u["device_id"]: u["id"] for u in stats["users"]}
        detail = (await client.get(f"/admin/users/{ids[onboarded]}")).json()
        empty = (await client.get(f"/admin/users/{ids[bare]}")).json()

    p = detail["profile"]
    assert p is not None, "expected the onboarding answers"
    for field, expected in answers.items():
        assert p[field] == expected, field
    assert p["updated_at"], "expected when they answered"

    assert empty["profile"] is None, "a user who never onboarded has no profile"


@pytest.mark.asyncio
async def test_last_seen_is_strap_data_only():
    """"Last seen" means the newest PolarH10 data — a strap recording or a
    metric sample. Opening the app is not being seen: an app-only user still
    appears in the table (they gave a sign of life) but their last_seen is
    empty, with the app signal reported separately. Requires a database."""
    from datetime import datetime, timezone, timedelta
    import uuid

    now = datetime.now(timezone.utc)
    sfx = uuid.uuid4().hex[:8]
    app_only, strap, metrics = f"test-app-{sfx}", f"test-strap2-{sfx}", f"test-ms-{sfx}"
    async with _client() as client:
        # Opened the app; never wore the strap.
        r = await client.post("/v1/usage", headers={"X-User-ID": app_only}, json={"events": [
            {"client_event_id": str(uuid.uuid4()), "event_type": "foreground",
             "ts": (now - timedelta(minutes=3)).isoformat(), "duration_ms": 300_000},
        ]})
        assert r.status_code == 200, r.text
        # Wore the strap.
        r = await client.post("/v1/usage", headers={"X-User-ID": strap}, json={"events": [
            {"client_event_id": str(uuid.uuid4()), "event_type": "ecg_recording",
             "ts": (now - timedelta(minutes=6)).isoformat(), "duration_ms": 600_000},
        ]})
        assert r.status_code == 200, r.text
        # Streamed strap-derived metrics, nothing else.
        r = await client.post("/v1/metrics", headers={"X-User-ID": metrics}, json={"samples": [
            {"ts": (now - timedelta(minutes=9)).isoformat(), "mean_bpm": 61.0, "rmssd": 40.0},
        ]})
        assert r.status_code in (200, 201), r.text

        data = (await client.get("/admin/stats", params={"range": "24h"})).json()

    rows = {u["device_id"]: u for u in data["users"]}

    # The app-only user is still listed — they were active — but the strap
    # never saw them, so last_seen is empty while the app signal is recorded.
    assert app_only in rows, "an app-only user is still active in range"
    assert rows[app_only]["last_seen"] is None
    assert rows[app_only]["last_signal"] is not None

    # Both strap sources set last_seen.
    assert rows[strap]["last_seen"] is not None
    assert rows[metrics]["last_seen"] is not None


@pytest.mark.asyncio
async def test_last_seen_ignores_valueless_metric_samples():
    """A metric sample with no values is not the sensor seeing anyone, so it
    must not drag last_seen past the last real reading — the mismatch that made
    a phone which stopped recording at 21:54 look live at 08:29 the next
    morning. Requires a database."""
    from datetime import datetime, timezone, timedelta
    import uuid

    now = datetime.now(timezone.utc)
    device = f"test-hollow-{uuid.uuid4().hex[:8]}"
    async with _client() as client:
        # A real reading two hours ago, then a valueless row one minute ago.
        r = await client.post("/v1/metrics", headers={"X-User-ID": device}, json={"samples": [
            {"ts": (now - timedelta(hours=2)).isoformat(), "mean_bpm": 62.0, "rmssd": 41.0},
        ]})
        assert r.status_code in (200, 201), r.text
        # Written directly: the ingest guard now refuses to store these, but
        # production already holds ~8k of them and the dashboard must be honest
        # about the ones already there.
        from server.db import get_pool
        async with get_pool().acquire() as conn:
            await conn.execute(
                "INSERT INTO metric_samples (user_id, ts) "
                "SELECT id, $2 FROM users WHERE device_id = $1 "
                "ON CONFLICT DO NOTHING",
                device, now - timedelta(minutes=1),
            )

        data = (await client.get("/admin/stats", params={"range": "24h"})).json()

    row = next(u for u in data["users"] if u["device_id"] == device)
    seen = datetime.fromisoformat(row["last_seen"])
    assert (now - seen) > timedelta(minutes=30), \
        f"last_seen {seen} tracked the valueless row instead of the real reading"


@pytest.mark.asyncio
async def test_user_table_lists_only_users_active_in_range():
    """The user table follows the range picker: a user shows up only if they
    gave some sign of life inside it — an app open, a strap session or a logged
    activity. Dormant accounts drop out instead of filling the table with
    dashes. Requires a database."""
    from datetime import datetime, timezone, timedelta
    import uuid

    now = datetime.now(timezone.utc)
    sfx = uuid.uuid4().hex[:8]
    recent_dev, stale_dev, act_dev = (
        f"test-recent-{sfx}", f"test-stale-{sfx}", f"test-act-only-{sfx}")

    async def _usage(client, device, ts, kind="foreground", ms=120_000):
        r = await client.post("/v1/usage", headers={"X-User-ID": device}, json={"events": [
            {"client_event_id": str(uuid.uuid4()), "event_type": kind,
             "ts": ts.isoformat(), "duration_ms": ms},
        ]})
        assert r.status_code == 200, r.text

    async with _client() as client:
        # Opened the app ten minutes ago — active in every range.
        await _usage(client, recent_dev, now - timedelta(minutes=10))
        # Last opened the app ten days ago — dormant in the short ranges.
        await _usage(client, stale_dev, now - timedelta(days=10))
        # No usage events at all, only a logged activity an hour ago. This is
        # the row that used to read "last seen: never" while showing activity.
        act = await client.post("/activities", headers={"X-User-ID": act_dev}, json={
            "id": str(uuid.uuid4()),
            "activity_type": "Meditation",
            "started_at": (now - timedelta(hours=1)).isoformat(),
            "ended_at": now.isoformat(),
        })
        assert act.status_code == 200, act.text

        day = (await client.get("/admin/stats", params={"range": "24h"})).json()
        wide = (await client.get("/admin/stats", params={"range": "90d"})).json()
        every = (await client.get("/admin/stats", params={"range": "all"})).json()

    def devices(payload):
        return {u["device_id"] for u in payload["users"]}

    assert recent_dev in devices(day)
    assert stale_dev not in devices(day), "a user dormant for 10 days is not active in 24h"
    assert {recent_dev, stale_dev} <= devices(wide)
    assert {recent_dev, stale_dev} <= devices(every)

    # An activity is a sign of life, so it keeps the user in the table — but a
    # logged activity is not PolarH10 data, so it does not set last_seen.
    assert act_dev in devices(day), "a logged activity counts as activity"
    row = next(u for u in day["users"] if u["device_id"] == act_dev)
    assert row["last_signal"] is not None, "the activity is the signal that keeps them listed"
    assert row["last_seen"] is None, "an activity is not strap data"

    # The table is a subset of the roster, and total_users stays the all-time
    # denominator rather than shrinking with the range.
    assert len(day["users"]) <= day["kpis"]["total_users"]
    assert len(day["users"]) < len(every["users"])
