"""Stress Balance is the saved 0–100 dial, independently of raw LF/HF."""
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import csv
import io
import uuid

import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app
from server.db import init_pool, close_pool, create_schema, get_pool, get_or_create_user


@asynccontextmanager
async def client():
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


def identity():
    return {"X-User-ID": "stress-" + uuid.uuid4().hex}


def instant():
    return datetime.now(timezone.utc).replace(hour=10, minute=0, second=0, microsecond=0) - timedelta(days=1)


@pytest.mark.asyncio
async def test_saved_snapshot_survives_export_and_retries_without_replacing_raw_metrics():
    async with client() as c:
        headers = identity()
        ts = instant().isoformat()
        sample = {"ts": ts, "rmssd": 40, "lf_hf": 9, "stress_balance": 17.5}
        assert (await c.post('/v1/metrics', headers=headers, json={"samples": [sample]})).status_code == 200
        # A stale client must neither erase nor recompute the snapshot; its
        # newly supplied timezone may still fill missing metadata.
        retry = {"ts": ts, "rmssd": 80, "lf_hf": 1, "timezone": "Australia/Sydney"}
        await c.post('/v1/metrics', headers=headers, json={"samples": [retry]})
        retry['stress_balance'] = 99
        await c.post('/v1/metrics', headers=headers, json={"samples": [retry]})
        rows = (await c.get('/v1/metrics/export', headers=headers)).json()['samples']
        assert len(rows) == 1
        assert rows[0]['stress_balance'] == 17.5
        assert rows[0]['lf_hf'] == 9 and rows[0]['rmssd'] == 40
        assert rows[0]['timezone'] == 'Australia/Sydney'
        assert not (await c.get('/v1/metrics/export', headers=identity())).json()['samples']


@pytest.mark.asyncio
async def test_legacy_uploads_feed_distinct_connector_stats_trend_day_and_samples():
    from server.mcp_server import _metric_stats, _metric_trend, _day_summary, _get_session_samples
    async with client() as c:
        headers = identity()
        start = instant()
        end = start + timedelta(minutes=1)
        body = {'samples': [
            {'ts': start.isoformat(), 'rmssd': 20, 'lf_hf': 9, 'breath_bpm': 6},
            {'ts': (start + timedelta(seconds=2)).isoformat(), 'rmssd': 160, 'lf_hf': 9, 'breath_bpm': 6},
        ]}
        await c.post('/v1/metrics', headers=headers, json=body)
        uid = await get_or_create_user(headers['X-User-ID'])
        expected = (100 * (1 - 20 / 60) + 20) / 2
        stats = await _metric_stats(uid, 'stress_balance', start.isoformat(), end.isoformat())
        assert stats['metric'] == 'stress_balance'
        assert stats['n'] == 2 and stats['avg'] == pytest.approx(expected, abs=.001)
        assert (await _metric_stats(uid, 'lf_hf', start.isoformat(), end.isoformat()))['avg'] == 9
        trend = await _metric_trend(uid, 'stress_balance', start.isoformat(), end.isoformat(), 1)
        assert trend[0]['value'] == pytest.approx(expected, abs=.001)
        day = await _day_summary(uid, start.date().isoformat())
        assert day['stress_balance']['avg'] == pytest.approx(expected, abs=.001)
        sid = await get_pool().fetchval("INSERT INTO activities (user_id, activity_type, started_at, ended_at) VALUES ($1, 'Walk', $2, $3) RETURNING id", uid, start, end)
        samples = await _get_session_samples(uid, str(sid))
        assert [s['stress_balance'] for s in samples] == pytest.approx([66.666666, 20])
        minute = (await c.get('/v1/metrics/minutes', headers=headers, params={'start': start.isoformat(), 'end': end.isoformat()})).json()['minutes'][0]
        assert minute['metrics']['stress_balance']['mean'] == pytest.approx(expected)
        series = (await c.get(f'/admin/activities/{sid}/series')).json()['samples']
        assert all(s['stress_balance'] is not None for s in series)


@pytest.mark.asyncio
async def test_connector_session_summary_exposes_saved_activity_stress():
    from server.mcp_server import _get_session, _list_sessions
    async with client():
        uid = await get_or_create_user(identity()['X-User-ID'])
        sid = await get_pool().fetchval("INSERT INTO activities (user_id, activity_type, started_at, ended_at, before_stress, during_stress, after_stress) VALUES ($1, 'Walk', $2, $3, 60, 40, 30) RETURNING id", uid, instant(), instant()+timedelta(minutes=5))
        for result in [await _get_session(uid, str(sid)), (await _list_sessions(uid, 10, None, None))[0]]:
            assert result['before_stress_balance'] == 60
            assert result['avg_stress_balance'] == 40
            assert result['after_stress_balance'] == 30


@pytest.mark.asyncio
@pytest.mark.parametrize('value', [-1, 101, 'NaN', 'Infinity', '-Infinity'])
async def test_out_of_range_or_nonfinite_stored_dials_are_rejected(value):
    async with client() as c:
        r = await c.post('/v1/metrics', headers=identity(), json={'samples': [{'ts': instant().isoformat(), 'stress_balance': value}]})
        assert r.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize('rmssd,ratio,breath,expected', [
    (40, 9, 6, 50), (20, .2, 14, 66.666666), (160, 9, 6, 20),
    (.1, None, None, 95), (100000, None, None, 5),
    (None, 4, 14, 80), (None, 4, None, 80), (None, 4, 6, None),
    (None, 0, 14, 0), (None, None, 14, None),
    (float('nan'), None, 14, None), (float('inf'), None, 14, None),
    (None, float('nan'), 14, None), (None, -1, 14, None),
])
async def test_sql_legacy_formula_matches_app_semantics(rmssd, ratio, breath, expected):
    async with client():
        value = await get_pool().fetchval('SELECT wythin_stress_balance($1, $2, $3)', rmssd, ratio, breath)
        if expected is None:
            assert value is None
        else:
            assert value == pytest.approx(expected, abs=.0001)


@pytest.mark.asyncio
async def test_backfill_only_missing_values_and_is_repeatable():
    from server.stress_balance import backfill_stress_balance
    async with client() as c:
        headers = identity()
        uid = await get_or_create_user(headers['X-User-ID'])
        ts = instant()
        await get_pool().executemany('INSERT INTO metric_samples (user_id, ts, rmssd, stress_balance, received_at) VALUES ($1, $2, $3, $4, $2)', [
            (uid, ts, 40, None), (uid, ts+timedelta(seconds=2), 40, 17),
            (uid, ts+timedelta(seconds=4), None, None),
        ])
        await backfill_stress_balance(get_pool(), batch_size=1)
        rows = (await c.get('/v1/metrics/export', headers=headers)).json()['samples']
        assert [r['stress_balance'] for r in rows] == [50, 17, None]
        assert rows[0]['received_at'] == rows[0]['ts']
        assert await backfill_stress_balance(get_pool(), batch_size=1) == 0


@pytest.mark.asyncio
async def test_legacy_session_csv_includes_saved_and_derived_dials():
    async with client() as c:
        ts = instant().isoformat()
        r = await c.post('/sessions', headers=identity(), json={'started_at': ts, 'ended_at': ts, 'samples': [
            {'ts': ts, 'rmssd': 40, 'lf_hf': 9, 'stress_balance': 17.5},
            {'ts': ts, 'rmssd': 40, 'lf_hf': 9},
        ]})
        assert r.status_code == 200, r.text
        exported = await c.get('/admin/sessions/'+r.json()['id']+'/export')
        rows = list(csv.DictReader(io.StringIO(exported.text)))
        assert sorted(float(r['stress_balance']) for r in rows) == [17.5, 50]
        assert all(float(r['lf_hf']) == 9 for r in rows)
