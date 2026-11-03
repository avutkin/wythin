from __future__ import annotations
from contextlib import asynccontextmanager
import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app
from datetime import datetime, timedelta, timezone


# Stamps relative to now: the test reads its rows back through the 30-day
# window, which a fixed date fell out of.
def _ts(minute, second=0):
    base = datetime.now(timezone.utc).replace(hour=11, minute=0, second=0, microsecond=0) - timedelta(days=1)
    return (base + timedelta(minutes=minute, seconds=second)).strftime("%Y-%m-%dT%H:%M:%SZ")

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
        body = {"samples": [_sample(_ts(0, 0), 30), _sample(_ts(0, 2), 31)]}
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200 and r.json()["stored"] == 2
        # Re-post same ts → no duplicates (ON CONFLICT DO NOTHING)
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200

@pytest.mark.asyncio
async def test_delete_my_data_scoped_to_token_user():
    async with _client() as c:
        await c.post("/v1/metrics", json={"samples": [_sample(_ts(60, 0), 30)]},
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
            _sample(_ts(60, 0), 30),                      # real
            {"ts": _ts(60, 2)},                           # every metric null
            {"ts": _ts(60, 4), "mean_bpm": None, "rmssd": None},
            _sample(_ts(60, 6), 31),                      # real
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
            {"ts": _ts(60, 8), "coherence": 0.5},
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
            _sample(_ts(0, i), 30 + i) for i in range(3)]})
        await c.post("/v1/metrics", headers={"X-User-ID": other}, json={"samples": [
            _sample(_ts(0, 0), 99)]})

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


@pytest.mark.asyncio
async def test_motion_round_trips_through_upload_and_export():
    """Motion is the channel the sleep pipeline leans on hardest, and until
    2026-09-06 it never left the phone — so a night that scored wrong could
    only be examined with the device in hand, and `tools/profile_night.py`
    could not reproduce what the device did. It has to survive the round trip
    or the tooling is back to guessing."""
    import uuid
    device = f"ms-motion-{uuid.uuid4().hex[:8]}"
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": device}, json={"samples": [
            {"ts": "2026-09-06T04:00:00Z", "mean_bpm": 57.0, "motion": 3.9},   # asleep
            {"ts": "2026-09-06T05:00:00Z", "mean_bpm": 88.0, "motion": 61.2},  # moving
            {"ts": "2026-09-06T06:00:00Z", "mean_bpm": 60.0},                  # no motion carried
        ]})
        assert r.status_code == 200, r.text
        assert r.json()["stored"] == 3

        page = (await c.get("/v1/metrics/export", headers={"X-User-ID": device})).json()
        motions = [s["motion"] for s in page["samples"]]
        assert motions[0] == pytest.approx(3.9, abs=0.01)
        assert motions[1] == pytest.approx(61.2, abs=0.01)
        assert motions[2] is None, "a sample that carried no motion stays null, not zero"


@pytest.mark.asyncio
async def test_a_sample_carrying_only_motion_is_still_a_reading():
    """Motion counts as a metric for the valueless-sample filter. Without it a
    tick that measured stillness and nothing else would be dropped at ingest as
    an empty timestamp — and stillness is exactly what a sleeping body reports."""
    import uuid
    device = f"ms-motion-only-{uuid.uuid4().hex[:8]}"
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": device}, json={"samples": [
            {"ts": "2026-09-06T04:00:00Z", "motion": 4.1},
        ]})
        assert r.status_code == 200, r.text
        assert r.json()["stored"] == 1


@pytest.mark.asyncio
async def test_signal_quality_round_trips_through_upload_and_export():
    """signal_quality, rr_invalid_rate and ecg_quality_tier are the on-device
    read of how trustworthy a tick is — the night that read 160 bpm with
    RMSSD 150 ms for ten hours (2026-10-24) carried no such signal on the
    server, so there was no way to tell a garbage stretch from a real one
    without SSHing in and eyeballing raw numbers. They must survive the
    round trip or the dashboard has nothing to show."""
    import uuid
    device = f"ms-quality-{uuid.uuid4().hex[:8]}"
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": device}, json={"samples": [
            {"ts": "2026-10-24T04:00:00Z", "mean_bpm": 58.0,
             "signal_quality": 0.97, "rr_invalid_rate": 0.01, "ecg_quality_tier": 2},
            {"ts": "2026-10-24T08:00:00Z", "mean_bpm": 165.0,
             "signal_quality": 0.12, "rr_invalid_rate": 0.74, "ecg_quality_tier": 0},
            {"ts": "2026-10-24T12:00:00Z", "mean_bpm": 60.0},  # no quality carried
        ]})
        assert r.status_code == 200, r.text
        assert r.json()["stored"] == 3

        page = (await c.get("/v1/metrics/export", headers={"X-User-ID": device})).json()
        s = page["samples"]
        assert s[0]["signal_quality"] == pytest.approx(0.97, abs=0.01)
        assert s[0]["rr_invalid_rate"] == pytest.approx(0.01, abs=0.01)
        assert s[0]["ecg_quality_tier"] == 2
        assert s[1]["ecg_quality_tier"] == 0 and s[1]["rr_invalid_rate"] == pytest.approx(0.74, abs=0.01)
        assert s[2]["ecg_quality_tier"] is None, "a sample that carried no quality stays null, not zero"
@pytest.mark.asyncio
async def test_minute_summary_preserves_breath_extremes_and_missing_minutes():
    """Averages must expose their coverage and must not hide a silent minute."""
    import uuid
    owner = f"ms-min-{uuid.uuid4().hex[:8]}"
    other = f"ms-min-{uuid.uuid4().hex[:8]}"
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": owner}, json={"samples": [
            {"ts": "2026-07-27T10:00:01Z", "breath_bpm": 12, "mean_bpm": 60},
            {"ts": "2026-07-27T10:00:03Z", "breath_bpm": 18, "mean_bpm": 70},
            {"ts": "2026-07-27T10:00:05Z", "mean_bpm": 80},
            {"ts": "2026-07-27T10:02:01Z", "breath_bpm": 14},
        ]})
        assert r.status_code == 200, r.text
        await c.post("/v1/metrics", headers={"X-User-ID": other}, json={"samples": [
            {"ts": "2026-07-27T10:00:07Z", "breath_bpm": 40},
        ]})
        summary = await c.get("/v1/metrics/minutes", headers={"X-User-ID": owner}, params={
            "start": "2026-07-27T10:00:00Z", "end": "2026-07-27T10:03:00Z"})
        assert summary.status_code == 200, summary.text
        minutes = summary.json()["minutes"]
        assert len(minutes) == 3
        assert minutes[0]["sample_count"] == 3
        assert minutes[0]["expected_samples"] == 30
        assert minutes[0]["metrics"]["breath_bpm"] == {
            "mean": 15.0, "min": 12.0, "max": 18.0, "count": 2}
        assert minutes[0]["metrics"]["mean_bpm"] == {
            "mean": 70.0, "min": 60.0, "max": 80.0, "count": 3}
        assert minutes[1]["sample_count"] == 0
        assert minutes[1]["metrics"]["breath_bpm"]["mean"] is None
        assert minutes[2]["metrics"]["breath_bpm"]["mean"] == 14.0


@pytest.mark.asyncio
async def test_minute_summary_rejects_unbounded_ranges():
    import uuid
    async with _client() as c:
        r = await c.get("/v1/metrics/minutes",
                        headers={"X-User-ID": f"ms-min-{uuid.uuid4().hex[:8]}"},
                        params={"start": "2026-07-27T00:00:00Z",
                                "end": "2026-07-29T00:00:00Z"})
        assert r.status_code == 422


@pytest.mark.asyncio
async def test_metric_upload_records_first_server_receipt_time():
    """Collection time and server arrival time must be distinguishable."""
    import uuid
    from datetime import datetime, timezone
    from server.db import get_pool, get_or_create_user

    device = f"ms-received-{uuid.uuid4().hex[:8]}"
    sample = {"samples": [{"ts": "2026-10-26T09:06:00Z", "mean_bpm": 65}]}
    async with _client() as c:
        r = await c.post("/v1/metrics", headers={"X-User-ID": device}, json=sample)
        assert r.status_code == 200, r.text
        user_id = await get_or_create_user(device)
        first = await get_pool().fetchval(
            "SELECT received_at FROM metric_samples WHERE user_id=$1 AND ts=$2",
            uuid.UUID(user_id), datetime(2026, 10, 26, 9, 6, tzinfo=timezone.utc))
        assert first is not None
        assert abs((datetime.now(timezone.utc) - first).total_seconds()) < 10

        retry = await c.post("/v1/metrics", headers={"X-User-ID": device}, json=sample)
        assert retry.status_code == 200
        page = await c.get("/v1/metrics/export", headers={"X-User-ID": device})
        assert page.json()["samples"][0]["received_at"] == first.isoformat()
