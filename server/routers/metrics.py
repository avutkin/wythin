"""POST /v1/metrics — batch upload of continuous HRV samples (opt-in cloud sync).
Shared-key gated; scoped to the caller's user via X-User-ID."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException
from datetime import datetime

from ..db import get_pool, get_or_create_user
from ..models import MetricsUpload

router = APIRouter(prefix="/v1/metrics", tags=["metrics"])

_MAX_BATCH = 5000
_COLS = ["mean_bpm","rmssd","sdnn","pnn50","lf_hf","rsa_ms","coherence","cbi",
         "breath_bpm","dfa1","rcmse","pip","dc","vti",
         "rsa_idx","ie_ratio","ials","motion","signal_quality",
         "rr_invalid_rate","rr_corrected_rate","ecg_quality_tier",
         "ulf_power","vlf_power","lf_power","hf_power"]


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.post("")
async def upload_metrics(body: MetricsUpload, x_user_id: str = Header(..., alias="X-User-ID")):
    if len(body.samples) > _MAX_BATCH:
        raise HTTPException(status_code=413, detail=f"max {_MAX_BATCH} samples per request")
    user_id = await get_or_create_user(x_user_id)
    rows = [
        tuple([user_id, _dt(s.ts)] + [getattr(s, c) for c in _COLS])
        for s in body.samples
    ]
    if not rows:
        return {"stored": 0}
    placeholders = ", ".join(f"${i}" for i in range(1, len(_COLS) + 3))
    # COALESCE, not a bare EXCLUDED: a re-upload that omits a column must leave
    # the stored value alone. Bare EXCLUDED would null it out.
    updates = ", ".join(
        f"{c} = COALESCE(EXCLUDED.{c}, metric_samples.{c})" for c in _COLS
    )
    sql = (
        f"INSERT INTO metric_samples (user_id, ts, {', '.join(_COLS)}) "
        f"VALUES ({placeholders}) "
        f"ON CONFLICT (user_id, ts) DO UPDATE SET {updates}"
    )
    async with get_pool().acquire() as conn:
        await conn.executemany(sql, rows)
    return {"stored": len(rows)}
