from __future__ import annotations
from contextlib import asynccontextmanager
import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app

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
        body = {"samples": [_sample("2026-07-27T10:00:00Z", 30), _sample("2026-07-27T10:00:02Z", 31)]}
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200 and r.json()["stored"] == 2
        # Re-post same ts → ON CONFLICT DO UPDATE rewrites the same values in
        # place (no new row), so the observable result is still idempotent.
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-A"})
        assert r.status_code == 200

@pytest.mark.asyncio
async def test_delete_my_data_scoped_to_token_user():
    async with _client() as c:
        await c.post("/v1/metrics", json={"samples": [_sample("2026-07-27T11:00:00Z", 30)]},
                     headers={"X-User-ID": "ms-del"})
        tok = (await c.post("/v1/tokens", json={"name": "t"}, headers={"X-User-ID": "ms-del"})).json()["token"]
        r = await c.delete("/v1/me/data", headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 200
        assert r.json()["metric_samples"] >= 1


_NEW_COLS = ["rsa_idx", "ie_ratio", "ials", "motion", "signal_quality",
             "rr_invalid_rate", "rr_corrected_rate", "ecg_quality_tier",
             "ulf_power", "vlf_power", "lf_power", "hf_power"]


@pytest.mark.asyncio
async def test_new_metric_columns_exist_and_round_trip():
    from server.db import get_pool
    async with _client() as c:
        body = {"samples": [{
            "ts": "2026-07-28T09:00:00Z",
            "mean_bpm": 61.0,
            "rsa_idx": 0.42, "ie_ratio": 1.6, "ials": 0.21, "motion": 12.5,
            "signal_quality": 0.93, "rr_invalid_rate": 0.01,
            "rr_corrected_rate": 0.02, "ecg_quality_tier": 2,
            "ulf_power": 100.0, "vlf_power": 200.0,
            "lf_power": 300.0, "hf_power": 400.0,
        }]}
        r = await c.post("/v1/metrics", json=body, headers={"X-User-ID": "ms-wide"})
        assert r.status_code == 200, r.text

        async with get_pool().acquire() as conn:
            row = await conn.fetchrow(
                "SELECT " + ", ".join(_NEW_COLS) + " FROM metric_samples ms "
                "JOIN users u ON u.id = ms.user_id "
                "WHERE u.device_id = 'ms-wide' AND ms.ts = '2026-07-28T09:00:00Z'")
        assert row is not None, "sample row was not stored"
        assert row["motion"] == pytest.approx(12.5)
        assert row["ecg_quality_tier"] == 2
        assert row["hf_power"] == pytest.approx(400.0)
        assert row["signal_quality"] == pytest.approx(0.93)


@pytest.mark.asyncio
async def test_reupload_enriches_without_erasing():
    from server.db import get_pool
    ts = "2026-07-28T09:30:00Z"
    async with _client() as c:
        # First upload: the old 14-field shape (no motion, no quality).
        await c.post("/v1/metrics", headers={"X-User-ID": "ms-enrich"},
                     json={"samples": [{"ts": ts, "mean_bpm": 60.0, "rmssd": 41.0}]})
        # Second upload: same ts, adds the new fields, omits rmssd entirely.
        await c.post("/v1/metrics", headers={"X-User-ID": "ms-enrich"},
                     json={"samples": [{"ts": ts, "mean_bpm": 60.0,
                                        "motion": 8.25, "ecg_quality_tier": 1}]})

        async with get_pool().acquire() as conn:
            row = await conn.fetchrow(
                "SELECT rmssd, motion, ecg_quality_tier FROM metric_samples ms "
                "JOIN users u ON u.id = ms.user_id "
                "WHERE u.device_id = 'ms-enrich' AND ms.ts = $1",
                __import__("datetime").datetime.fromisoformat(ts.replace("Z", "+00:00")))
        assert row["motion"] == pytest.approx(8.25), "new field was not written on conflict"
        assert row["ecg_quality_tier"] == 1
        assert row["rmssd"] == pytest.approx(41.0), "omitted field was erased by the re-upload"
