from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
from httpx import AsyncClient, ASGITransport
from server.main import app


@asynccontextmanager
async def _client():
    from server.db import init_pool, close_pool, create_schema
    await init_pool()
    await create_schema()
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
            yield c
    finally:
        await close_pool()


@pytest.mark.asyncio
async def test_resolve_bearer_valid_and_invalid():
    from server.auth_user import resolve_bearer, AuthError
    async with _client() as c:
        made = (await c.post("/v1/tokens", json={"name": "mcp"},
                             headers={"X-User-ID": "mcp-auth-user"})).json()
        raw = made["token"]
        # Valid
        uid = await resolve_bearer(f"Bearer {raw}")
        assert isinstance(uid, str) and uid
        # Missing / malformed
        with pytest.raises(AuthError):
            await resolve_bearer(None)
        with pytest.raises(AuthError):
            await resolve_bearer("Bearer not-a-wyth-token")
        # Revoked → AuthError
        await c.delete(f"/v1/tokens/{made['id']}", headers={"X-User-ID": "mcp-auth-user"})
        with pytest.raises(AuthError):
            await resolve_bearer(f"Bearer {raw}")


@pytest.mark.asyncio
async def test_tool_helpers_scope_to_user():
    from server.db import get_or_create_user, get_pool
    from server.mcp_server import (
        _list_sessions, _get_session, _get_session_samples, _whoami,
    )
    from server.db import init_pool, close_pool, create_schema
    await init_pool()
    await create_schema()
    try:
        uid_a = await get_or_create_user("mcp-scope-A")
        uid_b = await get_or_create_user("mcp-scope-B")
        async with get_pool().acquire() as conn:
            sid = await conn.fetchval(
                "INSERT INTO sessions (user_id, started_at, avg_rsa_ms) "
                "VALUES ($1, NOW(), 30) RETURNING id", uid_a)
            await conn.execute(
                "INSERT INTO hrv_samples (session_id, ts, mean_bpm, rmssd) "
                "VALUES ($1, NOW(), 62, 40)", str(sid))

        # A sees exactly its session; B sees none
        assert len(await _list_sessions(uid_a, 50, None, None)) == 1
        assert await _list_sessions(uid_b, 50, None, None) == []

        # Ownership enforced: B cannot read A's session or samples
        with pytest.raises(ValueError):
            await _get_session(uid_b, str(sid))
        with pytest.raises(ValueError):
            await _get_session_samples(uid_b, str(sid))

        # A can
        assert (await _get_session(uid_a, str(sid)))["id"] == str(sid)
        assert len(await _get_session_samples(uid_a, str(sid))) == 1
        assert (await _whoami(uid_a))["id"] == uid_a
    finally:
        await close_pool()


@pytest.mark.asyncio
async def test_mcp_tools_registered_and_mounted():
    from server.mcp_server import mcp
    tools = {t.name for t in await mcp.list_tools()}
    assert {"whoami", "list_sessions", "get_session", "get_session_samples",
            "get_day_summary", "get_metric_trend", "get_metric_stats"} <= tools
    assert any(getattr(r, "path", "") == "/mcp" for r in app.routes)


@pytest.mark.asyncio
async def test_metric_tools_scope_and_aggregate():
    from server.db import get_or_create_user, get_pool
    from server.mcp_server import _day_summary, _metric_trend, _metric_stats, _parse_dt
    import server.db as _  # ensure module import
    from server.db import init_pool, close_pool, create_schema
    await init_pool(); await create_schema()
    try:
        a = await get_or_create_user("mt-A"); b = await get_or_create_user("mt-B")
        async with get_pool().acquire() as conn:
            for i, pip in enumerate([40, 30, 20]):
                await conn.execute(
                    "INSERT INTO metric_samples (user_id, ts, pip, mean_bpm) VALUES ($1,$2,$3,$4) "
                    "ON CONFLICT DO NOTHING",
                    a, _parse_dt(f"2026-07-27T10:0{i}:00Z"), float(pip), 60.0)
        summ = await _day_summary(a, "2026-07-27")
        assert summ["pip"]["min"] == 20 and summ["pip"]["max"] == 40 and summ["pip"]["n"] == 3
        # user B sees nothing
        summ_b = await _day_summary(b, "2026-07-27")
        assert summ_b == {} or summ_b.get("pip", {}).get("n", 0) == 0
        stats = await _metric_stats(a, "inner_noise", "2026-07-27T00:00:00Z", "2026-07-28T00:00:00Z")
        assert stats["n"] == 3 and stats["min"] == 20
        trend = await _metric_trend(a, "pip", "2026-07-27T10:00:00Z", "2026-07-27T10:03:00Z", buckets=3)
        assert len(trend) >= 1
    finally:
        await close_pool()


def test_resolve_metric_alias_and_reject():
    from server.mcp_server import _resolve_metric
    assert _resolve_metric("inner_noise") == "pip"
    assert _resolve_metric("pip") == "pip"
    with pytest.raises(ValueError):
        _resolve_metric("; DROP TABLE")


@pytest.mark.asyncio
async def test_new_metrics_resolve_and_aggregate():
    from server.db import get_or_create_user
    from server.mcp_server import _resolve_metric, _metric_stats, _day_summary
    async with _client() as c:
        # Column names resolve directly.
        assert _resolve_metric("motion") == "motion"
        assert _resolve_metric("hf_power") == "hf_power"
        assert _resolve_metric("ecg_quality_tier") == "ecg_quality_tier"
        # Friendly aliases resolve to columns.
        assert _resolve_metric("stillness") == "motion"
        assert _resolve_metric("quality") == "signal_quality"
        assert _resolve_metric("breathing_ratio") == "ie_ratio"
        assert _resolve_metric("fragmentation") == "ials"
        # Unknown names are still rejected (no SQL-column injection).
        with pytest.raises(ValueError):
            _resolve_metric("motion; DROP TABLE users")

        await c.post("/v1/metrics", headers={"X-User-ID": "mcp-wide"}, json={"samples": [
            {"ts": "2026-07-28T12:00:00Z", "motion": 10.0, "signal_quality": 0.9},
            {"ts": "2026-07-28T12:00:02Z", "motion": 20.0, "signal_quality": 0.8},
        ]})
        uid = await get_or_create_user("mcp-wide")

        stats = await _metric_stats(uid, "stillness",
                                    "2026-07-28T00:00:00Z", "2026-07-29T00:00:00Z")
        assert stats["metric"] == "motion"
        assert stats["n"] == 2
        assert stats["avg"] == pytest.approx(15.0)

        summary = await _day_summary(uid, "2026-07-28")
        assert "motion" in summary, "day summary must cover the new columns"
        assert summary["signal_quality"]["n"] == 2


@pytest.mark.asyncio
async def test_ecg_quality_tier_aggregate_is_numeric_not_decimal_string():
    """`ecg_quality_tier` is the only INT column, so Postgres' avg() returns
    `numeric` and asyncpg hands back a `Decimal` — which serializes to a JSON
    *string* (e.g. "1.500") unless coerced. Every other metric's avg() is
    already a plain float; this one must match, or MCP clients see one metric
    silently switch shape from number to string."""
    from server.db import get_or_create_user
    from server.mcp_server import _metric_stats, _day_summary, _metric_trend
    async with _client() as c:
        await c.post("/v1/metrics", headers={"X-User-ID": "mcp-ecg-tier"}, json={"samples": [
            {"ts": "2026-07-28T13:00:00Z", "ecg_quality_tier": 1},
            {"ts": "2026-07-28T13:00:02Z", "ecg_quality_tier": 2},
        ]})
        uid = await get_or_create_user("mcp-ecg-tier")

        stats = await _metric_stats(uid, "ecg_quality_tier",
                                     "2026-07-28T00:00:00Z", "2026-07-29T00:00:00Z")
        assert isinstance(stats["avg"], float), \
            f"expected a float, got {type(stats['avg'])} ({stats['avg']!r})"
        assert stats["avg"] == pytest.approx(1.5)

        summary = await _day_summary(uid, "2026-07-28")
        assert isinstance(summary["ecg_quality_tier"]["avg"], float)

        trend = await _metric_trend(uid, "ecg_quality_tier",
                                     "2026-07-28T00:00:00Z", "2026-07-29T00:00:00Z", buckets=1)
        assert trend and isinstance(trend[0]["value"], float)

        # No rows at all: avg must stay a genuine null, not be coerced to 0.0.
        empty_stats = await _metric_stats(uid, "ecg_quality_tier",
                                           "2020-01-01T00:00:00Z", "2020-01-02T00:00:00Z")
        assert empty_stats["avg"] is None
