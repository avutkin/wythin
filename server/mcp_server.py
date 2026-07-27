"""Server-side MCP endpoint: read-only, token-scoped tools over the caller's
own sessions and HRV samples. Mounted at /mcp by server.main.

Every tool resolves the user_id from the request's Authorization header and
scopes all queries to it — no tool accepts a user_id argument.
"""
from __future__ import annotations

import uuid as _uuid
from datetime import datetime
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
