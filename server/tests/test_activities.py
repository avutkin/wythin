"""
Activity upload + dashboard exposure tests. Require PostgreSQL (set DATABASE_URL).
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


_PAYLOAD = {
    "id":               "00000000-0000-0000-0000-0000000000c3",
    "activity_type":    "Meditation",
    "activity_subtype": "Body Scan",
    "started_at":       "2025-04-01T07:00:00Z",
    "ended_at":         "2025-04-01T07:15:00Z",
    "is_manual":        False,
    "impact_score":     72,
    "impact_delta_pct": 8.4,
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
        mine = [a for a in acts if a["client_activity_id"] == _PAYLOAD["id"]]
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
        assert len([a for a in acts if a["client_activity_id"] == _PAYLOAD["id"]]) == 1


@pytest.mark.asyncio
async def test_impact_delta_pct_round_trips():
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c4"
        payload["impact_delta_pct"] = -12.5
        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-activity-user"})
        assert up.status_code == 200

        acts = await _user_activities(client, "test-activity-user")
        mine = next(a for a in acts if a["client_activity_id"] == payload["id"])
        assert mine["impact_delta_pct"] == -12.5


@pytest.mark.asyncio
async def test_impact_delta_pct_is_optional():
    # Builds shipped before this field must keep uploading successfully.
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c5"
        payload.pop("impact_delta_pct", None)
        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-activity-user"})
        assert up.status_code == 200


@pytest.mark.asyncio
async def test_reupload_without_impact_score_does_not_clobber_it():
    # The current app no longer sends impact_score at all (Task 9 replaced it
    # with impact_delta_pct). A re-upload omitting the field entirely — e.g. a
    # fresh-install backfill re-sending every local ActivityLog — must not
    # blank out a real historical score that a prior (older) build wrote.
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c6"
        payload["impact_score"] = 55
        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-activity-user"})
        assert up.status_code == 200

        reupload = dict(_PAYLOAD)
        reupload["id"] = payload["id"]
        reupload.pop("impact_score", None)
        reupload["impact_delta_pct"] = -3.0
        up2 = await client.post("/activities", json=reupload,
                                headers={"X-User-ID": "test-activity-user"})
        assert up2.status_code == 200

        acts = await _user_activities(client, "test-activity-user")
        mine = next(a for a in acts if a["client_activity_id"] == payload["id"])
        assert mine["impact_score"] == 55, "absent impact_score must not clobber the stored value"
        assert mine["impact_delta_pct"] == -3.0, "impact_delta_pct should still update normally"


@pytest.mark.asyncio
async def test_breath_rate_round_trips():
    """Breath Rate is the ninth stored metric. A phone restoring its history
    from the server has to get it back, or the tile reads "—" on every session
    that predates the reinstall while the card still counts nine."""
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c8"
        payload["before_breath"] = 14.2
        payload["during_breath"] = 6.4
        payload["after_breath"]  = 9.1

        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-breath-user"})
        assert up.status_code == 200

        back = await client.get("/activities", headers={"X-User-ID": "test-breath-user"})
        assert back.status_code == 200
        row = next(a for a in back.json() if a["id"] == payload["id"])
        assert row["before_breath"] == pytest.approx(14.2)
        assert row["during_breath"] == pytest.approx(6.4)
        assert row["after_breath"]  == pytest.approx(9.1)


@pytest.mark.asyncio
async def test_an_upload_without_breath_rate_is_still_accepted():
    """Older builds send no breath columns at all. Absence has to stay absence
    rather than becoming an error or a zero."""
    async with _client() as client:
        payload = dict(_PAYLOAD)
        payload["id"] = "00000000-0000-0000-0000-0000000000c9"

        up = await client.post("/activities", json=payload,
                               headers={"X-User-ID": "test-breath-legacy-user"})
        assert up.status_code == 200

        back = await client.get("/activities", headers={"X-User-ID": "test-breath-legacy-user"})
        row = next(a for a in back.json() if a["id"] == payload["id"])
        assert row["before_breath"] is None
        assert row["during_breath"] is None
        assert row["after_breath"] is None


# ── Nights ───────────────────────────────────────────────────────────────

_NIGHT = {
    "score": 72,
    "arithmetic": "72 = 25%·65 + 25%·80 + 15%·60 + 20%·75 + 15%·70",
    "stage_summary": "6h 02m quiet · 1h 20m active · 0h 30m awake",
    "asleep_min": 442, "in_bed_min": 472, "regularity": 81.0, "algorithm_version": 13,
    "sections": {"timing": 65, "duration": 80, "continuity": 60, "autonomic": 75, "breathing": 70},
    "stages": {"wake": 30, "rem": 90, "n1": 40, "n2": 240, "n3": 72},
    "wake_bouts": 3, "longest_wake_min": 12,
    "lowest_hr": 47.0, "lowest_hr_at": "2025-04-02T03:10:00Z",
    "position_recorded": True,
    "positions": [{"position": "Left side", "minutes": 250}, {"position": "Supine", "minutes": 180}],
    "position_bands": [{"position": "Left side", "start": "2025-04-01T23:00:00Z", "end": "2025-04-02T03:10:00Z"}],
    "stage_runs": [{"stage": "n2", "start": "2025-04-01T23:00:00Z", "end": "2025-04-02T00:00:00Z"}],
}


def _night(cid, start, end, **extra):
    body = {"id": cid, "activity_type": "Sleep", "started_at": start, "ended_at": end,
            "is_manual": False, "sleep": dict(_NIGHT, **extra)}
    return body


@pytest.mark.asyncio
async def test_a_night_round_trips_its_sleep_block():
    """The app's night — score, sections, stages, positions, hypnogram — is
    stored as uploaded and comes back on the detail and on the user's list."""
    dev = "test-night-user-a"
    body = _night("00000000-0000-0000-0000-0000000000d1", "2025-04-01T23:00:00Z", "2025-04-02T06:52:00Z")
    async with _client() as client:
        up = await client.post("/activities", json=body, headers={"X-User-ID": dev})
        assert up.status_code == 200, up.text
        detail = (await client.get(f"/admin/activities/{up.json()['id']}")).json()
        listed = await _user_activities(client, dev)
    assert detail["sleep"] == _NIGHT
    assert detail["impact"]["class"] == "restorative"
    mine = next(a for a in listed if a["id"] == up.json()["id"])
    assert mine["sleep"]["score"] == 72


@pytest.mark.asyncio
async def test_an_activity_without_a_sleep_block_stores_null():
    async with _client() as client:
        up = await client.post("/activities", json=_PAYLOAD, headers={"X-User-ID": "test-activity-user"})
        detail = (await client.get(f"/admin/activities/{up.json()['id']}")).json()
    assert detail["sleep"] is None


@pytest.mark.asyncio
async def test_a_rebuilt_night_replaces_the_one_it_overlaps():
    """The app purges and re-records nights on an algorithm bump or a
    correction, under a new id. One night per window: the newcomer deletes
    any Sleep row of the same user whose window overlaps it, and nothing
    else — a night on another date, or another user's night, stays."""
    dev, other = "test-night-user-b", "test-night-user-c"
    old   = _night("00000000-0000-0000-0000-0000000000d2", "2025-05-01T23:00:00Z", "2025-05-02T06:30:00Z", algorithm_version=12)
    new   = _night("00000000-0000-0000-0000-0000000000d3", "2025-05-01T23:20:00Z", "2025-05-02T06:45:00Z", algorithm_version=13)
    apart = _night("00000000-0000-0000-0000-0000000000d4", "2025-05-02T23:00:00Z", "2025-05-03T06:30:00Z")
    theirs = _night("00000000-0000-0000-0000-0000000000d5", "2025-05-01T23:00:00Z", "2025-05-02T06:30:00Z")
    async with _client() as client:
        for body, who in ((old, dev), (apart, dev), (theirs, other)):
            assert (await client.post("/activities", json=body, headers={"X-User-ID": who})).status_code == 200
        assert (await client.post("/activities", json=new, headers={"X-User-ID": dev})).status_code == 200
        mine = await _user_activities(client, dev)
        others = await _user_activities(client, other)
    ids = {a["client_activity_id"] for a in mine}
    assert new["id"] in ids and apart["id"] in ids
    assert old["id"] not in ids, "the overlapped night must be gone"
    assert theirs["id"] in {a["client_activity_id"] for a in others}


@pytest.mark.asyncio
async def test_a_meditation_never_displaces_a_night():
    """Only Sleep rows take part in the overlap rule: a practice logged in
    the middle of a night — a nap, a 3 a.m. breathing session — sits beside
    it."""
    dev = "test-night-user-d"
    night = _night("00000000-0000-0000-0000-0000000000d6", "2025-06-01T23:00:00Z", "2025-06-02T06:30:00Z")
    sit = dict(_PAYLOAD, id="00000000-0000-0000-0000-0000000000d7",
               started_at="2025-06-02T03:00:00Z", ended_at="2025-06-02T03:15:00Z")
    async with _client() as client:
        assert (await client.post("/activities", json=night, headers={"X-User-ID": dev})).status_code == 200
        assert (await client.post("/activities", json=sit, headers={"X-User-ID": dev})).status_code == 200
        mine = await _user_activities(client, dev)
    assert {a["client_activity_id"] for a in mine} >= {night["id"], sit["id"]}


@pytest.mark.asyncio
async def test_activity_carries_the_zone_it_was_recorded_in():
    """Each upload names the phone's zone at the time, so a night recorded on
    a trip keeps its own clock after the person flies home. The detail page
    also carries the profile's zone as the fallback for rows uploaded by an
    older app that sent none."""
    async with _client() as client:
        await client.post("/v1/profile", json={"timezone": "America/Los_Angeles"},
                          headers={"X-User-ID": "test-tz-user"})
        trip = {**_PAYLOAD, "id": "00000000-0000-0000-0000-0000000000c4", "timezone": "Asia/Tokyo"}
        up = await client.post("/activities", json=trip, headers={"X-User-ID": "test-tz-user"})
        assert up.status_code == 200, up.text
        d = (await client.get(f"/admin/activities/{up.json()['id']}")).json()
        assert d["timezone"] == "Asia/Tokyo"
        assert d["user_timezone"] == "America/Los_Angeles"

        old = {**_PAYLOAD, "id": "00000000-0000-0000-0000-0000000000c5"}
        up = await client.post("/activities", json=old, headers={"X-User-ID": "test-tz-user"})
        d = (await client.get(f"/admin/activities/{up.json()['id']}")).json()
        assert d["timezone"] is None
        assert d["user_timezone"] == "America/Los_Angeles"

        bogus = {**_PAYLOAD, "id": "00000000-0000-0000-0000-0000000000c6", "timezone": "Not/AZone"}
        up = await client.post("/activities", json=bogus, headers={"X-User-ID": "test-tz-user"})
        assert up.status_code == 200
        d = (await client.get(f"/admin/activities/{up.json()['id']}")).json()
        assert d["timezone"] is None

        acts = await _user_activities(client, "test-tz-user")
        assert next(a for a in acts if a["client_activity_id"] == trip["id"])["timezone"] == "Asia/Tokyo"
