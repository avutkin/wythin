"""
GET /admin/dashboard       — self-contained HTML user-activity dashboard
GET /admin/stats           — aggregate usage stats (KPIs, sessions/day, per-user)
GET /admin/users           — list all users + last-seen
GET /admin/users/{id}      — per-user summary
GET /admin/sessions        — all sessions (recent)
GET /admin/sessions/{id}/export  — CSV download
"""
from __future__ import annotations

import csv
import io
from pathlib import Path
from fastapi import APIRouter
from fastapi.responses import StreamingResponse, HTMLResponse
from ..db import get_pool
from ..models import AdminUserRow

router = APIRouter(prefix="/admin", tags=["admin"])

# Loaded once at import. The page itself carries NO data — it fetches /admin/stats
# with the X-API-Key header — so serving the shell without the key gate is safe.
_DASHBOARD_HTML = (
    Path(__file__).resolve().parent.parent / "templates" / "dashboard.html"
).read_text(encoding="utf-8")


@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard_page() -> HTMLResponse:
    return HTMLResponse(_DASHBOARD_HTML)


@router.get("/stats")
async def usage_stats(days: int = 90):
    """Aggregate usage: headline KPIs, a sessions-per-day series, and a per-user
    activity table. `days` bounds the time series (default 90)."""
    days = max(1, min(days, 730))
    pool = get_pool()
    async with pool.acquire() as conn:
        kpi = await conn.fetchrow(
            """
            SELECT
              (SELECT COUNT(*) FROM users)                                    AS total_users,
              (SELECT COUNT(DISTINCT user_id) FROM sessions
                 WHERE started_at > NOW() - INTERVAL '7 days')                AS active_7d,
              (SELECT COUNT(DISTINCT user_id) FROM sessions
                 WHERE started_at > NOW() - INTERVAL '30 days')               AS active_30d,
              (SELECT COUNT(*) FROM sessions)                                 AS total_sessions,
              (SELECT COALESCE(SUM(EXTRACT(EPOCH FROM (ended_at - started_at)) / 60.0), 0)
                 FROM sessions WHERE ended_at IS NOT NULL)                    AS total_minutes,
              (SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (ended_at - started_at)) / 60.0), 0)
                 FROM sessions WHERE ended_at IS NOT NULL)                    AS avg_session_min
            """
        )
        series = await conn.fetch(
            """
            SELECT date_trunc('day', started_at)::date AS day, COUNT(*) AS sessions
            FROM sessions
            WHERE started_at > NOW() - ($1::int * INTERVAL '1 day')
            GROUP BY day
            ORDER BY day
            """,
            days,
        )
        users = await conn.fetch(
            """
            SELECT
              u.id, u.device_id, u.display_name,
              u.created_at                       AS first_seen,
              MAX(s.started_at)                  AS last_seen,
              COUNT(s.id)                        AS session_count,
              COALESCE(SUM(EXTRACT(EPOCH FROM (s.ended_at - s.started_at)) / 60.0), 0) AS total_minutes,
              AVG(s.avg_coherence)               AS avg_coherence,
              AVG(s.avg_rsa_ms)                  AS avg_rsa
            FROM users u
            LEFT JOIN sessions s ON s.user_id = u.id
            GROUP BY u.id
            ORDER BY last_seen DESC NULLS LAST
            """
        )

    def _f(v):
        return float(v) if v is not None else None

    return {
        "kpis": {
            "total_users":     kpi["total_users"],
            "active_7d":       kpi["active_7d"],
            "active_30d":      kpi["active_30d"],
            "total_sessions":  kpi["total_sessions"],
            "total_minutes":   round(_f(kpi["total_minutes"]), 1),
            "avg_session_min": round(_f(kpi["avg_session_min"]), 1),
        },
        "sessions_per_day": [
            {"day": r["day"].isoformat(), "sessions": r["sessions"]} for r in series
        ],
        "users": [
            {
                "id":            str(r["id"]),
                "device_id":     r["device_id"],
                "display_name":  r["display_name"],
                "first_seen":    r["first_seen"].isoformat() if r["first_seen"] else None,
                "last_seen":     r["last_seen"].isoformat() if r["last_seen"] else None,
                "session_count": r["session_count"],
                "total_minutes": round(_f(r["total_minutes"]), 1),
                "avg_coherence": round(_f(r["avg_coherence"]), 3) if r["avg_coherence"] is not None else None,
                "avg_rsa":       round(_f(r["avg_rsa"]), 1) if r["avg_rsa"] is not None else None,
            }
            for r in users
        ],
    }


@router.get("/users", response_model=list[AdminUserRow])
async def list_users():
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                u.id,
                u.device_id,
                MAX(s.started_at) AS last_seen,
                COUNT(s.id)       AS session_count
            FROM users u
            LEFT JOIN sessions s ON s.user_id = u.id
            GROUP BY u.id
            ORDER BY last_seen DESC NULLS LAST
            """
        )
    return [
        AdminUserRow(
            id=str(r["id"]),
            device_id=r["device_id"],
            last_seen=r["last_seen"].isoformat() if r["last_seen"] else None,
            session_count=r["session_count"],
        )
        for r in rows
    ]


@router.get("/sessions")
async def list_all_sessions(limit: int = 100):
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                s.id, s.started_at, s.ended_at,
                s.avg_rsa_ms, s.avg_coherence,
                u.device_id
            FROM sessions s
            JOIN users u ON u.id = s.user_id
            ORDER BY s.started_at DESC
            LIMIT $1
            """,
            limit,
        )
    return [
        {
            "id":            str(r["id"]),
            "started_at":    r["started_at"].isoformat(),
            "ended_at":      r["ended_at"].isoformat() if r["ended_at"] else None,
            "avg_rsa_ms":    r["avg_rsa_ms"],
            "avg_coherence": r["avg_coherence"],
            "device_id":     r["device_id"],
        }
        for r in rows
    ]


@router.get("/sessions/{session_id}/export")
async def export_session_csv(session_id: str):
    """Download all hrv_samples for a session as CSV."""
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf,
                   rsa_ms, rsa_idx, coherence, cbi, breath_bpm
            FROM hrv_samples
            WHERE session_id = $1::uuid
            ORDER BY ts
            """,
            session_id,
        )

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["ts", "mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf",
                     "rsa_ms", "rsa_idx", "coherence", "cbi", "breath_bpm"])
    for r in rows:
        writer.writerow([
            r["ts"].isoformat(),
            r["mean_bpm"], r["rmssd"], r["sdnn"], r["pnn50"], r["lf_hf"],
            r["rsa_ms"], r["rsa_idx"], r["coherence"], r["cbi"], r["breath_bpm"],
        ])

    buf.seek(0)
    return StreamingResponse(
        iter([buf.read()]),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename=session_{session_id[:8]}.csv"},
    )
