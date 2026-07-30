"""
POST /activities — upload one logged activity (iOS ActivityLog).

Upserts on client_activity_id so re-uploads (backfill / retry) are idempotent.
"""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Header

from ..db import get_pool, get_or_create_user
from ..models import ActivitySchema, UploadResponse

router = APIRouter(prefix="/activities", tags=["activities"])

# before/during/after column names for every stored metric, in a fixed order.
_METRICS = ("hr", "rmssd", "sdnn", "rsa", "vti", "lfhf", "stress",
            "rcmse", "pip", "dc", "dfa1")
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
        "impact_delta_pct", "notes",
    ]
    cols = base_cols + _METRIC_COLS
    vals = [
        activity.id, user_db_id, activity.activity_type, activity.activity_subtype,
        activity.custom_name, _parse_dt(activity.started_at), _parse_dt(activity.ended_at),
        activity.is_manual, activity.impact_score, activity.impact_delta_pct, activity.notes,
    ] + [getattr(activity, c) for c in _METRIC_COLS]

    placeholders = ", ".join(f"${i + 1}" for i in range(len(cols)))
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
        row = await conn.fetchrow(sql, *vals)
    return UploadResponse(id=str(row["id"]))
