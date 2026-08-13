"""POST /v1/metrics — batch upload of continuous HRV samples (opt-in cloud sync).
Shared-key gated; scoped to the caller's user via X-User-ID."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException
from datetime import datetime, timezone

from ..db import get_pool, get_or_create_user
from ..models import MetricsUpload

router = APIRouter(prefix="/v1/metrics", tags=["metrics"])

_MAX_BATCH = 5000
_COLS = ["mean_bpm","rmssd","sdnn","pnn50","lf_hf","rsa_ms","coherence","cbi",
         "breath_bpm","dfa1","rcmse","pip","dc","vti"]


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.post("")
async def upload_metrics(body: MetricsUpload, x_user_id: str = Header(..., alias="X-User-ID")):
    if len(body.samples) > _MAX_BATCH:
        raise HTTPException(status_code=413, detail=f"max {_MAX_BATCH} samples per request")
    user_id = await get_or_create_user(x_user_id)
    # A sample with every metric null measures nothing — it is a timestamp
    # pretending to be a reading. Stored, they inflate row counts and drag
    # "last seen" forward past the last real measurement, which is how a phone
    # that stopped recording last night still looked live this morning.
    rows = []
    for s in body.samples:
        values = [getattr(s, c) for c in _COLS]
        if any(v is not None for v in values):
            rows.append(tuple([user_id, _dt(s.ts)] + values))
    skipped = len(body.samples) - len(rows)
    if not rows:
        return {"stored": 0, "skipped": skipped}
    placeholders = ", ".join(f"${i}" for i in range(1, len(_COLS) + 3))
    sql = (
        f"INSERT INTO metric_samples (user_id, ts, {', '.join(_COLS)}) "
        f"VALUES ({placeholders}) ON CONFLICT (user_id, ts) DO NOTHING"
    )
    async with get_pool().acquire() as conn:
        await conn.executemany(sql, rows)
    return {"stored": len(rows), "skipped": skipped}


@router.get("/export")
async def export_metrics(
    x_user_id: str = Header(..., alias="X-User-ID"),
    cursor: str | None = None,
    limit: int = 5000,
):
    """Paged read-back of this user's own samples, oldest first.

    The counterpart to the POST above, for a phone whose local store is gone:
    page with `cursor` = the previous page's `next_cursor` until it comes back
    null. Scoped to the caller's user row like every other read.
    """
    limit = min(max(limit, 1), _MAX_BATCH)
    user_id = await get_or_create_user(x_user_id)
    after = _dt(cursor) if cursor else datetime(1970, 1, 1, tzinfo=timezone.utc)
    pool = await get_pool()
    rows = await pool.fetch(
        f"SELECT ts, {', '.join(_COLS)} FROM metric_samples "
        "WHERE user_id = $1 AND ts > $2 ORDER BY ts LIMIT $3",
        user_id, after, limit)
    samples = [
        {"ts": r["ts"].isoformat(), **{c: r[c] for c in _COLS}}
        for r in rows
    ]
    return {
        "samples": samples,
        "next_cursor": samples[-1]["ts"] if len(rows) == limit else None,
    }
