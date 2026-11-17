"""Recording clocks survive flights, delayed uploads and old clients."""
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import uuid

import pytest
from httpx import ASGITransport, AsyncClient
from server.main import app


@asynccontextmanager
async def client():
    from server.db import init_pool, create_schema, close_pool
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


async def upload(c, samples):
    from server.db import get_pool
    device = "travel-" + uuid.uuid4().hex
    headers = {"X-User-ID": device}
    response = await c.post("/v1/metrics", headers=headers, json={"samples": samples})
    assert response.status_code == 200, response.text
    uid = await get_pool().fetchval("SELECT id FROM users WHERE device_id=$1", device)
    return headers, uid


@pytest.mark.asyncio
async def test_recording_zones_export_and_survive_legacy_duplicate():
    async with client() as c:
        samples = [
            {"ts": "2026-11-11T19:30:00Z", "mean_bpm": 60, "timezone": "Asia/Dubai"},
            {"ts": "2026-11-12T19:30:00Z", "mean_bpm": 62, "timezone": "Europe/Moscow"},
            {"ts": "2026-11-13T19:30:00Z", "mean_bpm": 64},
            {"ts": "2026-11-14T19:30:00Z", "mean_bpm": 65, "timezone": "Not/AZone"},
        ]
        headers, _ = await upload(c, samples)
        # An older client re-uploading cannot erase or overwrite known history.
        await c.post("/v1/metrics", headers=headers, json={"samples": [
            {"ts": samples[0]["ts"], "mean_bpm": 99},
            {"ts": samples[1]["ts"], "mean_bpm": 99, "timezone": "America/Los_Angeles"},
        ]})
        page = (await c.get("/v1/metrics/export", headers=headers)).json()["samples"]
        assert [s["timezone"] for s in page] == ["Asia/Dubai", "Europe/Moscow", None, None]
        assert [s["mean_bpm"] for s in page] == [60, 62, 64, 65]
        assert datetime.fromisoformat(page[0]["ts"]) == datetime(2026, 11, 11, 19, 30, tzinfo=timezone.utc)


@pytest.mark.asyncio
async def test_known_zone_can_fill_legacy_null_but_zone_alone_is_not_a_reading():
    async with client() as c:
        headers, _ = await upload(c, [{"ts": "2026-11-11T08:00:00Z", "mean_bpm": 60}])
        r = await c.post("/v1/metrics", headers=headers, json={"samples": [
            {"ts": "2026-11-11T08:00:00Z", "mean_bpm": 60, "timezone": "Asia/Dubai"},
            {"ts": "2026-11-11T08:00:02Z", "timezone": "Asia/Dubai"},
        ]})
        assert r.json() == {"stored": 1, "skipped": 1}
        page = (await c.get("/v1/metrics/export", headers=headers)).json()["samples"]
        assert len(page) == 1 and page[0]["timezone"] == "Asia/Dubai"


@pytest.mark.asyncio
async def test_admin_series_preserves_zones_when_aggregating():
    async with client() as c:
        start = datetime(2026, 11, 11, tzinfo=timezone.utc)
        samples = [{"ts": (start + timedelta(seconds=i)).isoformat(),
                    "mean_bpm": 60 if i % 2 else 80,
                    "timezone": "Asia/Dubai" if i % 2 else "Europe/Moscow"}
                   for i in range(3100)]
        _, uid = await upload(c, samples)
        for end in (start + timedelta(seconds=10), start + timedelta(hours=2)):
            result = await c.get(f"/admin/users/{uid}/metrics", params={
                "from": start.isoformat(), "to": end.isoformat()})
            assert result.status_code == 200, result.text
            points = result.json()["samples"]
            assert {p["timezone"] for p in points} == {"Asia/Dubai", "Europe/Moscow"}
            # A bucket cannot blend two clocks into a point with an arbitrary zone.
            assert all(p["mean_bpm"] == (60 if p["timezone"] == "Asia/Dubai" else 80) for p in points)


@pytest.mark.asyncio
async def test_track_groups_each_record_in_its_own_local_day():
    async with client() as c:
        headers, uid = await upload(c, [
            {"ts": "2026-11-10T20:30:00Z", "mean_bpm": 60, "timezone": "Asia/Dubai"},
            {"ts": "2026-11-11T20:30:00Z", "mean_bpm": 80, "timezone": "Asia/Dubai"},
            {"ts": "2026-11-11T20:40:00Z", "mean_bpm": 64, "timezone": "Europe/Moscow"},
            {"ts": "2026-11-13T12:00:00Z", "mean_bpm": 70},
        ])
        await c.post("/v1/profile", headers=headers, json={"timezone": "Europe/Moscow"})
        d = (await c.get(f"/admin/users/{uid}/track", params={
            "period": "week", "from": "2026-11-11", "zone": "Europe/Moscow"})).json()
        bars = next(m["bars"] for m in d["metrics"] if m["key"] == "mean_bpm")
        assert bars[0]["value"] == 62  # Dubai 00:30 + Moscow 23:40, both Nov 11
        assert bars[1]["value"] == 80  # Dubai 00:30 Nov 12, despite Moscow profile
        assert d["timezones"] == ["Asia/Dubai", "Europe/Moscow"]
        assert d["has_unknown_timezone"] is True
        assert d["fallback_timezone"] == "Europe/Moscow"
        utc = (await c.get(f"/admin/users/{uid}/track", params={
            "period": "week", "from": "2026-11-11", "clock": "utc"})).json()
        assert next(m["bars"] for m in utc["metrics"] if m["key"] == "mean_bpm")[0]["value"] == 72


@pytest.mark.asyncio
async def test_track_dst_uses_the_offset_at_measurement_time():
    async with client() as c:
        _, uid = await upload(c, [
            # The 25-hour New York day: first and last half hours both belong Nov 1.
            {"ts": "2026-11-01T04:30:00Z", "mean_bpm": 60, "timezone": "America/New_York"},
            {"ts": "2026-11-02T04:30:00Z", "mean_bpm": 80, "timezone": "America/New_York"},
            {"ts": "2026-11-02T05:30:00Z", "mean_bpm": 100, "timezone": "America/New_York"},
        ])
        r = await c.get(f"/admin/users/{uid}/track", params={
            "period": "week", "from": "2026-11-01", "zone": "America/New_York"})
        assert r.status_code == 200, r.text
        bars = next(m["bars"] for m in r.json()["metrics"] if m["key"] == "mean_bpm")
        assert [b["value"] for b in bars[:2]] == [70, 100]


@pytest.mark.asyncio
async def test_activity_restore_and_legacy_retry_preserve_zone_and_sleep():
    async with client() as c:
        headers = {"X-User-ID": "travel-activity-" + uuid.uuid4().hex}
        activity = {"id": str(uuid.uuid4()), "activity_type": "Sleep",
                    "started_at": "2026-11-10T19:00:00Z", "ended_at": "2026-11-11T03:00:00Z",
                    "timezone": "Asia/Dubai", "sleep": {"score": 83}}
        r = await c.post("/activities", headers=headers, json=activity)
        assert r.status_code == 200, r.text
        rows = (await c.get("/activities", headers=headers)).json()
        assert rows[0]["timezone"] == "Asia/Dubai"
        assert rows[0]["sleep"] == {"score": 83}
        # A pre-migration store cannot erase a known zone merely by resyncing.
        activity.pop("timezone")
        await c.post("/activities", headers=headers, json=activity)
        assert (await c.get("/activities", headers=headers)).json()[0]["timezone"] == "Asia/Dubai"
        # Build 146 still stamps the upload zone. Its retry after travel must
        # not rewrite the already saved clock of the same activity.
        activity["timezone"] = "Europe/Moscow"
        await c.post("/activities", headers=headers, json=activity)
        assert (await c.get("/activities", headers=headers)).json()[0]["timezone"] == "Asia/Dubai"
