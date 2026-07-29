"""POST /v1/usage — batch upload of app-usage events (opt-in cloud sync).

Two event kinds share one table:
  - 'foreground'     — app was in the foreground; duration_ms = active time.
  - 'ecg_recording'  — strap connect→disconnect; duration_ms = wear time.

Shared-key gated (like /v1/metrics); scoped to the caller via X-User-ID.
Idempotent on client_event_id so retries never duplicate.
"""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Header, HTTPException

from ..db import get_pool, get_or_create_user
from ..models import UsageUpload

router = APIRouter(prefix="/v1/usage", tags=["usage"])

_MAX_BATCH = 5000


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.post("")
async def upload_usage(body: UsageUpload, x_user_id: str = Header(..., alias="X-User-ID")):
    if len(body.events) > _MAX_BATCH:
        raise HTTPException(status_code=413, detail=f"max {_MAX_BATCH} events per request")
    if not body.events:
        return {"received": 0}

    user_id = await get_or_create_user(x_user_id)
    rows = [
        (user_id, e.event_type, _dt(e.ts), e.duration_ms, e.client_event_id)
        for e in body.events
    ]
    sql = (
        "INSERT INTO usage_events (user_id, event_type, ts, duration_ms, client_event_id) "
        "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (client_event_id) DO NOTHING"
    )
    async with get_pool().acquire() as conn:
        await conn.executemany(sql, rows)
    return {"received": len(rows)}
