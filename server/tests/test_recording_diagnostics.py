"""Recording diagnostics wire behavior against the real app and PostgreSQL."""
import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient

from server.db import close_pool, create_schema, get_pool, init_pool
from server.main import app

UPLOAD = "/v1/recording-diagnostics"


@asynccontextmanager
async def client():
    await init_pool()
    try:
        await create_schema()
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


def event(**changes):
    return {
        "schema_version": 1,
        "event_id": str(uuid4()),
        "installation_id": str(uuid4()),
        "launch_id": str(uuid4()),
        "launch_sequence": 1,
        "sequence": 1,
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "uptime_seconds": 101.5,
        "app_version": "1.0",
        "app_build": "156",
        "os_version": "26.1",
        "phase": "background",
        "reason": "heartbeat",
        "dropped_reports": 0,
        "sensor": {
            "central_state": "powered_on", "connection_state": "connected",
            "generation": 1, "rr_live": True, "ecg_live": True, "acc_live": True,
            "intended": True, "connection_age_seconds": 95,
        },
        "recording": {"computed_count": 0, "saved_count": 0, "failed_save_count": 0},
        "delivery": {"state": "idle", "queued_batches": 0, "in_flight": 0,
                     "maximum_attempts": 0, "pending_samples": 0},
        **changes,
    }


async def submit(c, device, *events, status=200):
    response = await c.post(UPLOAD, json={"events": events}, headers={"X-User-ID": device})
    assert response.status_code == status, response.text
    if status == 200:
        assert response.json() == {"accepted_ids": list(dict.fromkeys(e["event_id"] for e in events))}


async def user_id(device):
    return await get_pool().fetchval("SELECT id FROM users WHERE device_id = $1", device)


async def diagnostics(c, user):
    response = await c.get(f"/admin/users/{user}/recording-diagnostics")
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.asyncio
async def test_admin_and_upload_follow_shared_key_gate(monkeypatch):
    from server import auth

    monkeypatch.setattr(auth, "API_KEY", "diagnostics-test-key")
    device = str(uuid4())
    item = event()
    async with client() as c:
        assert (await c.post(UPLOAD, json={"events": [item]}, headers={"X-User-ID": device})).status_code == 401
        assert (await c.get(f"/admin/users/{uuid4()}/recording-diagnostics")).status_code == 401
        c.headers["X-API-Key"] = "diagnostics-test-key"
        assert (await c.post(UPLOAD, json={"events": [item]})).status_code == 422
        assert (await c.get(f"/admin/users/{uuid4()}/recording-diagnostics")).status_code == 404
        await submit(c, device, item)
        assert (await diagnostics(c, await user_id(device)))["installations"]


@pytest.mark.asyncio
async def test_replay_order_conflicts_and_isolation():
    device, other = str(uuid4()), str(uuid4())
    older = event(sequence=50)
    newer = {**older, "event_id": str(uuid4()), "launch_id": str(uuid4()),
             "launch_sequence": 2, "sequence": 1}
    separate = event()
    async with client() as c:
        await asyncio.gather(submit(c, device, newer), submit(c, device, newer))
        owner = await user_id(device)
        first = (await diagnostics(c, owner))["installations"][0]["latest"]["received_at"]
        await submit(c, device, newer, newer)
        replay = (await diagnostics(c, owner))["installations"][0]["latest"]
        assert replay["received_at"] == first
        await submit(c, device, older, separate)
        await submit(c, device, event(), {**newer, "app_build": "157"}, status=409)
        await submit(c, device, {**newer, "event_id": str(uuid4())}, status=409)
        # A differently serialized timestamp is changed wire content even
        # when it denotes the same instant.
        await submit(c, device, {**newer, "observed_at": newer["observed_at"].replace("+00:00", "Z")}, status=409)
        await submit(c, other, older)
        view = await diagnostics(c, owner)
        latest_ids = {item["latest"]["event_id"] for item in view["installations"]}
        assert latest_ids == {newer["event_id"], separate["event_id"]}
        assert {item["event_id"] for item in view["recent_events"]} == {
            newer["event_id"], older["event_id"], separate["event_id"],
        }
        other_view = await diagnostics(c, await user_id(other))
        assert [item["event_id"] for item in other_view["recent_events"]] == [older["event_id"]]


@pytest.mark.asyncio
async def test_validation_rejects_unbounded_and_unstructured_payloads():
    item = event()
    device = str(uuid4())
    async with client() as c:
        await submit(c, device, status=422)
        await submit(c, device, *[item] * 51, status=422)
        invalid = [
            {"schema_version": True}, {"event_id": "broken"}, {"sequence": 0},
            {"launch_sequence": 2**53}, {"dropped_reports": "0"},
            {"observed_at": "2760000000"}, {"observed_at": "2026-11-17T00:00:00"},
            {"uptime_seconds": -1}, {"app_version": "a@example"},
            {"recording": {**item["recording"], "raw_signal": [1, 2]}},
            {"recording": {**item["recording"], "rr_active_age_seconds": 315360001}},
            {"recording": {**item["recording"], "save_error_code": 2**31}},
            {"sensor": {**item["sensor"], "rr_live": 1}},
            {"delivery": {**item["delivery"], "last_http_status": 600}},
            {"reason": "arbitrary"},
        ]
        for changes in invalid:
            await submit(c, device, {**item, **changes}, status=422)
        r = await c.post(UPLOAD, json={"events": [item], "other": 1}, headers={"X-User-ID": device})
        assert r.status_code == 422
        assert await user_id(device) is None
        oversized = await c.post(UPLOAD, content=b" " * (256 * 1024 + 1),
                                 headers={"X-User-ID": device})
        assert oversized.status_code == 413


@pytest.mark.asyncio
async def test_retention_restart_timeline_and_cloud_deletion():
    from asgi_lifespan import LifespanManager

    device, other = str(uuid4()), str(uuid4())
    item, other_item = event(), event()
    async with client() as c:
        await submit(c, device, item)
        expired = event()
        await submit(c, device, expired)
        await submit(c, other, other_item)
        owner = await user_id(device)
        other_owner = await user_id(other)
        pool = get_pool()
        await pool.execute(
            """INSERT INTO recording_diagnostics
              (user_id,event_id,installation_id,launch_id,launch_sequence,sequence,observed_at,received_at,payload)
              SELECT user_id,new_id,installation_id,launch_id,launch_sequence,n,
                     observed_at,NOW() - INTERVAL '1 minute',
                     payload || jsonb_build_object('event_id', new_id, 'sequence', n)
              FROM recording_diagnostics
              CROSS JOIN (SELECT n, gen_random_uuid() AS new_id FROM generate_series(2,25002) AS n) generated
              WHERE user_id = $1 AND event_id = $2""", owner, item["event_id"],
        )
        await pool.execute(
            "UPDATE recording_diagnostics SET received_at = NOW() - INTERVAL '15 days' "
            "WHERE user_id = $1 OR (user_id = $2 AND event_id = $3)",
            other_owner, owner, expired["event_id"],
        )
        await submit(c, device, event())
        assert await pool.fetchval("SELECT COUNT(*) FROM recording_diagnostics WHERE user_id = $1", owner) == 25000
        assert not await pool.fetchval("SELECT TRUE FROM recording_diagnostics WHERE event_id = $1", expired["event_id"])
        assert await pool.fetchval("SELECT TRUE FROM recording_diagnostics WHERE user_id = $1", other_owner)
        timeline = (await diagnostics(c, owner))["recent_events"]
        assert len({item["event_id"] for item in timeline}) == 100

    async with LifespanManager(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            assert not await get_pool().fetchval("SELECT TRUE FROM recording_diagnostics WHERE user_id = $1", other_owner)
            assert (await diagnostics(c, other_owner))["recent_events"] == []
            token = await c.post("/v1/tokens", headers={"X-User-ID": device}, json={"name": "delete test"})
            deleted = await c.delete("/v1/me/data", headers={"Authorization": "Bearer " + token.json()["token"]})
            assert deleted.status_code == 200, deleted.text
            assert deleted.json()["recording_diagnostics"] == 25000
            assert (await diagnostics(c, owner))["installations"] == []


@pytest.mark.asyncio
async def test_freshness_and_metric_timestamp_cross_check():
    device = str(uuid4())
    now = datetime.now(timezone.utc)
    async with client() as c:
        metrics = await c.post("/v1/metrics", headers={"X-User-ID": device}, json={
            "samples": [{"ts": (now - timedelta(days=1)).isoformat(), "mean_bpm": 70}],
        })
        assert metrics.status_code == 200, metrics.text
        owner = await user_id(device)
        view = await diagnostics(c, owner)
        assert view["installations"] == []
        assert datetime.fromisoformat(view["last_metric_sample_at"]) == now - timedelta(days=1)
        assert datetime.fromisoformat(view["last_metric_received_at"]) >= now
        stale = event(observed_at=(now - timedelta(seconds=181)).isoformat())
        skewed = event(observed_at=(now + timedelta(seconds=121)).isoformat())
        receipt = event()
        await submit(c, device, stale, skewed, receipt)
        await get_pool().execute("UPDATE recording_diagnostics SET received_at = NOW() - INTERVAL '181 seconds' WHERE event_id = $1", receipt["event_id"])
        installs = (await diagnostics(c, owner))["installations"]
        assert len(installs) == 3
        for snapshot in installs:
            assert snapshot["freshness"] != "fresh"
            assert snapshot["stages"] == {"sensor": "unknown", "local": "unknown", "delivery": "unknown"}


@pytest.mark.asyncio
async def test_independent_stage_classification():
    device = str(uuid4())
    now = datetime.now(timezone.utc)
    cases = [
        ({}, {}, {}, ("receiving", "unknown", "up_to_date")),
        ({"rr_live": False}, {"computed_age_seconds": 99}, {}, ("rr_stalled", "unknown", "up_to_date")),
        ({"ecg_live": False}, {"rr_active_age_seconds": 61}, {}, ("ecg_stalled", "processing_stalled", "up_to_date")),
        ({}, {"rr_active_age_seconds": 60}, {}, ("receiving", "warming", "up_to_date")),
        ({}, {"rr_active_age_seconds": 61, "computed_count": 1, "computed_age_seconds": 60}, {}, ("receiving", "save_stalled", "up_to_date")),
        ({}, {"saved_count": 2, "saved_age_seconds": 61, "computed_age_seconds": 61, "rr_active_age_seconds": 61}, {}, ("receiving", "processing_stalled", "up_to_date")),
        ({}, {"saved_count": 1, "saved_age_seconds": 90, "rr_active_age_seconds": 5}, {}, ("receiving", "warming", "up_to_date")),
        ({}, {"saved_count": 1, "saved_age_seconds": 60}, {"state": "retrying"}, ("receiving", "recording", "retrying")),
        ({}, {"save_error_code": -1, "failed_save_count": 1}, {"state": "storage_blocked"}, ("receiving", "save_error", "storage_blocked")),
        ({"intended": False}, {"rr_active_age_seconds": 90}, {}, ("paused", "unknown", "up_to_date")),
        ({"connection_age_seconds": 20}, {}, {}, ("warming", "warming", "up_to_date")),
        ({"connection_state": "standby"}, {}, {"pending_samples": None}, ("standby", "unknown", "unknown")),
        ({"central_state": "powered_off"}, {}, {"pending_samples": 1, "oldest_queued_at": (now - timedelta(seconds=181)).isoformat()}, ("disconnected", "unknown", "awaiting_upload")),
        ({}, {}, {"pending_samples": 1, "oldest_queued_at": now.isoformat()}, ("receiving", "unknown", "uploading")),
    ]
    reports, expected = [], {}
    for sensor, recording, delivery, stages in cases:
        report = event()
        report["sensor"].update(sensor)
        report["recording"].update(recording)
        report["delivery"].update(delivery)
        reports.append(report)
        expected[report["installation_id"]] = dict(zip(("sensor", "local", "delivery"), stages))

    async with client() as c:
        await submit(c, device, *reports)
        view = await diagnostics(c, await user_id(device))
        assert all(row["freshness"] == "fresh" for row in view["installations"])
        assert {row["installation_id"]: row["stages"] for row in view["installations"]} == expected
