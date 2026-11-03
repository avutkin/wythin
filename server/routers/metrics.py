"""POST /v1/metrics — batch upload of continuous HRV samples (opt-in cloud sync).
Shared-key gated; scoped to the caller's user via X-User-ID."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException, Query
from datetime import datetime, timedelta, timezone
import math

from ..db import get_pool, get_or_create_user
from ..models import MetricsUpload

router = APIRouter(prefix="/v1/metrics", tags=["metrics"])

_MAX_BATCH = 5000
_COLS = ["mean_bpm","rmssd","sdnn","pnn50","lf_hf","rsa_ms","coherence","cbi",
         "breath_bpm","dfa1","rcmse","pip","dc","vti","motion",
         "signal_quality","rr_invalid_rate","ecg_quality_tier"]


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.get("/minutes")
async def minute_metrics(
    start: datetime = Query(...),
    end: datetime = Query(...),
    x_user_id: str = Header(..., alias="X-User-ID"),
):
    """One-minute summaries of the existing two-second scalar samples.

    Empty minutes are explicit. Each metric has its own non-null count: a
    present heart-rate value does not imply breathing was measured. The raw
    two-second samples remain available for closer event analysis.
    """
    if (start.tzinfo is None or end.tzinfo is None or end <= start
            or end - start > timedelta(days=1)):
        raise HTTPException(status_code=422, detail="use an aware, positive range of at most 24 hours")
    start = start.astimezone(timezone.utc)
    end = end.astimezone(timezone.utc)
    user_id = await get_or_create_user(x_user_id)
    aggregates = ["COUNT(*) AS sample_count"]
    for c in _COLS:
        aggregates.extend((f"AVG({c}) AS {c}_mean", f"MIN({c}) AS {c}_min",
                           f"MAX({c}) AS {c}_max", f"COUNT({c}) AS {c}_count"))
    rows = await get_pool().fetch(
        "SELECT date_trunc('minute', ts) AS bucket, " + ", ".join(aggregates)
        + " FROM metric_samples WHERE user_id = $1 AND ts >= $2 AND ts < $3"
          " GROUP BY bucket ORDER BY bucket", user_id, start, end)
    by_bucket = {r["bucket"]: r for r in rows}
    cursor = start.replace(second=0, microsecond=0)
    minutes = []
    while cursor < end:
        row = by_bucket.get(cursor)
        window_start = max(start, cursor)
        window_end = min(end, cursor + timedelta(minutes=1))
        expected = math.ceil((window_end - window_start).total_seconds() / 2)
        count = row["sample_count"] if row else 0
        metrics = {
            c: {
                "mean": row[f"{c}_mean"] if row else None,
                "min": row[f"{c}_min"] if row else None,
                "max": row[f"{c}_max"] if row else None,
                "count": row[f"{c}_count"] if row else 0,
            } for c in _COLS
        }
        minutes.append({
            "start": cursor.isoformat(), "sample_count": count,
            "expected_samples": expected,
            "coverage": min(count / expected, 1) if expected else 0,
            "metrics": metrics,
        })
        cursor += timedelta(minutes=1)
    return {"minutes": minutes}


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
        f"SELECT ts, received_at, {', '.join(_COLS)} FROM metric_samples "
        "WHERE user_id = $1 AND ts > $2 ORDER BY ts LIMIT $3",
        user_id, after, limit)
    samples = [
        {"ts": r["ts"].isoformat(),
         "received_at": r["received_at"].isoformat() if r["received_at"] else None,
         **{c: r[c] for c in _COLS}}
        for r in rows
    ]
    return {
        "samples": samples,
        "next_cursor": samples[-1]["ts"] if len(rows) == limit else None,
    }
