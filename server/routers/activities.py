"""
POST /activities — upload one logged activity (iOS ActivityLog).

Upserts on client_activity_id so re-uploads (backfill / retry) are idempotent.
"""
from __future__ import annotations

import json
from datetime import datetime

from fastapi import APIRouter, Header

from ..db import get_pool, get_or_create_user
from ..models import ActivitySchema, UploadResponse

router = APIRouter(prefix="/activities", tags=["activities"])

# before/during/after column names for every stored metric, in a fixed order.
_METRICS = ("hr", "rmssd", "sdnn", "rsa", "vti", "lfhf", "stress",
            "rcmse", "pip", "dc", "dfa1", "breath")
_METRIC_COLS = [f"{w}_{m}" for m in _METRICS for w in ("before", "during", "after")]


def _parse_dt(s: str | None):
    if s is None:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.post("", response_model=UploadResponse)
async def save_activity(
    activity: ActivitySchema,
    x_user_id: str = Header(..., alias="X-User-ID"),
):
    user_db_id = await get_or_create_user(x_user_id)

    base_cols = [
        "client_activity_id", "user_id", "activity_type", "activity_subtype",
        "custom_name", "started_at", "ended_at", "is_manual", "impact_score",
        "impact_delta_pct", "notes", "sleep", "timezone",
    ]
    cols = base_cols + _METRIC_COLS
    started, ended = _parse_dt(activity.started_at), _parse_dt(activity.ended_at)
    vals = [
        activity.id, user_db_id, activity.activity_type, activity.activity_subtype,
        activity.custom_name, started, ended,
        activity.is_manual, activity.impact_score, activity.impact_delta_pct, activity.notes,
        json.dumps(activity.sleep) if activity.sleep is not None else None,
        activity.timezone,
    ] + [getattr(activity, c) for c in _METRIC_COLS]

    placeholders = ", ".join(
        f"${i + 1}::jsonb" if c == "sleep" else f"${i + 1}" for i, c in enumerate(cols)
    )
    # impact_score is special: the current app never sends it (Task 9 replaced
    # it with impact_delta_pct), so it's absent — not explicitly null — on
    # every upload from a current build. A plain EXCLUDED overwrite would read
    # that absence as "clear the score" and blank out real values written by
    # older builds still in the field. COALESCE keeps a real incoming value
    # (older builds still upload one) and otherwise leaves the stored value
    # alone.
    updates = ", ".join(
        "impact_score = COALESCE(EXCLUDED.impact_score, activities.impact_score)"
        if c == "impact_score" else f"{c} = EXCLUDED.{c}"
        for c in cols if c != "client_activity_id"
    )
    sql = (
        f"INSERT INTO activities ({', '.join(cols)}) VALUES ({placeholders}) "
        f"ON CONFLICT (client_activity_id) DO UPDATE SET {updates} RETURNING id"
    )

    pool = get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            # One night per window. The app purges and re-records a night —
            # under a new id — on every algorithm bump and on every correction
            # the sleeper makes to its edges, and never tells the server about
            # the row it deleted. Without this, every rebuilt night sits beside
            # its predecessor and the same date shows twice. Only Sleep rows
            # take part: a practice logged in the middle of a night is a
            # different thing from a second copy of the night.
            if activity.activity_type == "Sleep" and ended is not None:
                await conn.execute(
                    """
                    DELETE FROM activities
                    WHERE user_id = $1 AND activity_type = 'Sleep'
                      AND client_activity_id <> $2
                      AND started_at < $4 AND COALESCE(ended_at, started_at) > $3
                    """,
                    user_db_id, activity.id, started, ended,
                )
            row = await conn.fetchrow(sql, *vals)
    return UploadResponse(id=str(row["id"]))


@router.get("", response_model=list[ActivitySchema])
async def list_activities(
    x_user_id: str = Header(..., alias="X-User-ID"),
    limit: int = 500,
):
    """Every activity this user has uploaded, newest first.

    The counterpart to the POST, and the reason it exists: a phone whose local
    store is gone — reinstalled, restored to a new device, or wiped — had no way
    to get its own history back, because upload was the only direction that
    existed. Reads are scoped to the caller's user row, so a token can only ever
    see its owner's activities.
    """
    user_db_id = await get_or_create_user(x_user_id)
    cols = ["client_activity_id", "activity_type", "activity_subtype",
            "custom_name", "started_at", "ended_at", "is_manual",
            "impact_score", "impact_delta_pct", "notes"] + _METRIC_COLS

    pool = await get_pool()
    rows = await pool.fetch(
        f"SELECT {', '.join(cols)} FROM activities WHERE user_id = $1 "
        "ORDER BY started_at DESC LIMIT $2",
        user_db_id, min(max(limit, 1), 2000))

    def iso(v):
        return v.isoformat() if v is not None else None

    return [
        ActivitySchema(
            id=r["client_activity_id"],
            activity_type=r["activity_type"],
            activity_subtype=r["activity_subtype"],
            custom_name=r["custom_name"],
            started_at=iso(r["started_at"]),
            ended_at=iso(r["ended_at"]),
            is_manual=r["is_manual"],
            impact_score=r["impact_score"],
            impact_delta_pct=r["impact_delta_pct"],
            notes=r["notes"],
            **{c: r[c] for c in _METRIC_COLS},
        )
        for r in rows
    ]
