"""POST /felt-state-logs — one self check-in from the phone.

The client half (FeltStateLog, FeltStateLogUploader, APIClient.uploadFeltStateLog)
shipped in August with nothing on this side, so the path and the single-object
body are fixed by a build already in the field. Shared-key gated like the
other uploads; scoped to the caller via X-User-ID; upserts on the phone's row
id so a retry after a dropped response never duplicates.
"""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Header

from ..db import get_pool, get_or_create_user
from ..models import FeltStateLogUpload, UploadResponse

router = APIRouter(prefix="/felt-state-logs", tags=["felt-state"])

_KINDS = {"moment", "previous_day"}

# Every column the phone can set. Absence on a re-send keeps the stored value:
# an older build omits keys it never knew, and that must not read as "clear".
_COLS = ["kind", "ts", "day_key", "timezone", "focus", "energy", "stress", "mood",
         "anxiety", "sleep", "state_key", "worn_minutes"]


def _dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


@router.post("", response_model=UploadResponse)
async def save_felt_state(body: FeltStateLogUpload,
                          x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    kind = body.kind if body.kind in _KINDS else "moment"
    vals = [body.id, user_id, kind, _dt(body.timestamp), body.day_key, body.timezone,
            body.focus, body.energy, body.stress, body.mood, body.anxiety, body.sleep,
            body.state_key, body.worn_minutes]
    cols = ["client_id", "user_id"] + _COLS
    placeholders = ", ".join(f"${i + 1}" for i in range(len(cols)))
    updates = ", ".join(f"{c} = COALESCE(EXCLUDED.{c}, felt_state_logs.{c})" for c in _COLS)
    sql = (
        f"INSERT INTO felt_state_logs ({', '.join(cols)}) VALUES ({placeholders}) "
        f"ON CONFLICT (client_id) DO UPDATE SET {updates} RETURNING id"
    )
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(sql, *vals)
    return UploadResponse(id=str(row["id"]))
