"""Server-side MCP endpoint: read-only, token-scoped tools over the caller's
own sessions and HRV samples. Mounted at /mcp by server.main.

Every tool resolves the user_id from the request's Authorization header and
scopes all queries to it — no tool accepts a user_id argument.
"""
from __future__ import annotations

import uuid as _uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from mcp.server.fastmcp import Context, FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .auth_user import resolve_bearer
from .db import get_pool

# This is a public, TLS-terminated (Caddy) endpoint authenticated per request by
# a Bearer token — that token is the access control. The SDK's DNS-rebinding
# Host check defends *local* servers from browser attacks and would otherwise
# reject (421 Misdirected Request) every request forwarded with the public Host
# header, so it is disabled here.
_MCP_SECURITY = TransportSecuritySettings(enable_dns_rebinding_protection=False)

mcp = FastMCP(name="Wythin", stateless_http=True, streamable_http_path="/",
              transport_security=_MCP_SECURITY)

_MAX_SESSIONS = 200
_MAX_SAMPLES = 5000


def _parse_dt(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _valid_uuid(s: str) -> str:
    try:
        return str(_uuid.UUID(s))
    except (ValueError, AttributeError, TypeError):
        raise ValueError("invalid session id")


async def _auth(ctx: Context) -> str:
    request = ctx.request_context.request
    header = request.headers.get("authorization") if request is not None else None
    return await resolve_bearer(header)


def _session_row(r) -> dict:
    return {
        "id": str(r["id"]),
        "started_at": r["started_at"].isoformat() if r["started_at"] else None,
        "ended_at": r["ended_at"].isoformat() if r["ended_at"] else None,
        "best_resonance_bpm": r["best_resonance_bpm"],
        "avg_rsa_ms": r["avg_rsa_ms"],
        "avg_coherence": r["avg_coherence"],
        "notes": r["notes"],
    }


# ---- data helpers (unit-testable without the MCP transport) ----

async def _whoami(user_id: str) -> dict:
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, display_name, created_at FROM users WHERE id = $1", user_id)
    if row is None:
        return {}
    return {"id": str(row["id"]), "display_name": row["display_name"],
            "created_at": row["created_at"].isoformat()}


async def _list_sessions(user_id: str, limit: int, since: Optional[str], until: Optional[str]) -> list[dict]:
    limit = max(1, min(int(limit), _MAX_SESSIONS))
    clauses = ["user_id = $1"]
    args: list = [user_id]
    dt_since, dt_until = _parse_dt(since), _parse_dt(until)
    if dt_since is not None:
        args.append(dt_since); clauses.append(f"started_at >= ${len(args)}")
    if dt_until is not None:
        args.append(dt_until); clauses.append(f"started_at < ${len(args)}")
    args.append(limit)
    sql = (
        "SELECT id, started_at, ended_at, best_resonance_bpm, avg_rsa_ms, avg_coherence, notes "
        "FROM sessions WHERE " + " AND ".join(clauses) +
        f" ORDER BY started_at DESC LIMIT ${len(args)}"
    )
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(sql, *args)
    return [_session_row(r) for r in rows]


async def _get_session(user_id: str, session_id: str) -> dict:
    sid = _valid_uuid(session_id)
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, started_at, ended_at, best_resonance_bpm, avg_rsa_ms, avg_coherence, notes "
            "FROM sessions WHERE id = $1 AND user_id = $2", sid, user_id)
    if row is None:
        raise ValueError("session not found")
    return _session_row(row)


async def _get_session_samples(user_id: str, session_id: str, limit: int = 2000) -> list[dict]:
    sid = _valid_uuid(session_id)
    limit = max(1, min(int(limit), _MAX_SAMPLES))
    async with get_pool().acquire() as conn:
        owns = await conn.fetchval(
            "SELECT 1 FROM sessions WHERE id = $1 AND user_id = $2", sid, user_id)
        if not owns:
            raise ValueError("session not found")
        rows = await conn.fetch(
            "SELECT ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi, breath_bpm "
            "FROM hrv_samples WHERE session_id = $1 ORDER BY ts LIMIT $2", sid, limit)
    return [
        {
            "ts": r["ts"].isoformat() if r["ts"] else None,
            "mean_bpm": r["mean_bpm"], "rmssd": r["rmssd"], "sdnn": r["sdnn"],
            "pnn50": r["pnn50"], "lf_hf": r["lf_hf"], "rsa_ms": r["rsa_ms"],
            "coherence": r["coherence"], "cbi": r["cbi"], "breath_bpm": r["breath_bpm"],
        }
        for r in rows
    ]


# ---- MCP tools (thin auth wrappers over the helpers) ----

@mcp.tool()
async def whoami(ctx: Context) -> dict:
    """Return your Wythin account info (id, display name). Confirms your token works."""
    return await _whoami(await _auth(ctx))


@mcp.tool()
async def list_sessions(ctx: Context, limit: int = 50,
                        since: Optional[str] = None, until: Optional[str] = None) -> list[dict]:
    """List your recorded HRV/breathing sessions, newest first.
    limit caps the count; since/until are ISO-8601 datetimes filtering by start time."""
    return await _list_sessions(await _auth(ctx), limit, since, until)


@mcp.tool()
async def get_session(ctx: Context, session_id: str) -> dict:
    """Get the summary of one of your sessions by its id."""
    return await _get_session(await _auth(ctx), session_id)


@mcp.tool()
async def get_session_samples(ctx: Context, session_id: str, limit: int = 2000) -> list[dict]:
    """Get the per-sample HRV rows (chronological) within one of your sessions."""
    return await _get_session_samples(await _auth(ctx), session_id, limit)


# ---- metric_samples aggregate tools ----

_METRIC_COLS = {"mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf", "rsa_ms", "coherence",
                "cbi", "breath_bpm", "dfa1", "rcmse", "pip", "dc", "vti"}
_METRIC_ALIASES = {
    "hr": "mean_bpm", "heart_rate": "mean_bpm", "pulse": "mean_bpm",
    "inner_noise": "pip", "harmony": "dfa1", "vagal_tone": "dc",
    "calm_power": "vti", "hrv": "rmssd", "stress_balance": "lf_hf",
}


def _resolve_metric(name: str) -> str:
    key = (name or "").strip().lower()
    col = _METRIC_ALIASES.get(key, key)
    if col not in _METRIC_COLS:
        raise ValueError(f"unknown metric '{name}'; valid: {sorted(_METRIC_COLS | set(_METRIC_ALIASES))}")
    return col


def _day_bounds(date: str):
    start = datetime.fromisoformat(date).replace(tzinfo=timezone.utc)
    return start, start + timedelta(days=1)


async def _day_summary(user_id: str, date: str) -> dict:
    start, end = _day_bounds(date)
    aggs = ", ".join(f"avg({c}) a_{c}, min({c}) mn_{c}, max({c}) mx_{c}, count({c}) n_{c}" for c in sorted(_METRIC_COLS))
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            f"SELECT {aggs} FROM metric_samples WHERE user_id=$1 AND ts>=$2 AND ts<$3",
            user_id, start, end)
    out = {}
    for c in sorted(_METRIC_COLS):
        n = row[f"n_{c}"] or 0
        if n:
            out[c] = {"avg": round(row[f"a_{c}"], 3), "min": row[f"mn_{c}"], "max": row[f"mx_{c}"], "n": n}
    return out


async def _metric_stats(user_id: str, metric: str, since: str, until: str) -> dict:
    col = _resolve_metric(metric)
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            f"SELECT avg({col}) a, min({col}) mn, max({col}) mx, count({col}) n "
            f"FROM metric_samples WHERE user_id=$1 AND ts>=$2 AND ts<$3",
            user_id, _parse_dt(since), _parse_dt(until))
    return {"metric": col, "avg": round(row["a"], 3) if row["a"] is not None else None,
            "min": row["mn"], "max": row["mx"], "n": row["n"] or 0}


async def _metric_trend(user_id: str, metric: str, since: str, until: str, buckets: int = 60) -> list[dict]:
    col = _resolve_metric(metric)
    s, e = _parse_dt(since), _parse_dt(until)
    buckets = max(1, min(int(buckets), 500))
    span = max((e - s).total_seconds(), 1.0)
    width = span / buckets
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(
            f"SELECT floor(extract(epoch from ts - $2) / $4)::int AS b, avg({col}) v "
            f"FROM metric_samples WHERE user_id=$1 AND ts>=$2 AND ts<$3 AND {col} IS NOT NULL "
            f"GROUP BY b ORDER BY b", user_id, s, e, width)
    return [{"t": (s + timedelta(seconds=r["b"] * width)).isoformat(), "value": round(r["v"], 3)} for r in rows]


@mcp.tool()
async def get_day_summary(ctx: Context, date: str) -> dict:
    """Per-metric avg/min/max/count for one UTC day (YYYY-MM-DD) of your data. Best for 'how was my X today'."""
    return await _day_summary(await _auth(ctx), date)


@mcp.tool()
async def get_metric_trend(ctx: Context, metric: str, since: str, until: str, buckets: int = 60) -> list[dict]:
    """Downsampled time series of one metric over [since, until) (ISO datetimes), ~`buckets` points. Metric accepts names/aliases like 'inner_noise', 'hr'."""
    return await _metric_trend(await _auth(ctx), metric, since, until, buckets)


@mcp.tool()
async def get_metric_stats(ctx: Context, metric: str, since: str, until: str) -> dict:
    """avg/min/max/count of one metric over [since, until). Good for comparisons across ranges."""
    return await _metric_stats(await _auth(ctx), metric, since, until)
