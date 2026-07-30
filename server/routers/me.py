"""Read-only, per-user endpoint scoped by the Bearer token's user_id.
The seed of the /v1/me/* API (SP2 expands it)."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from ..db import get_pool
from ..auth_user import current_user_id

router = APIRouter(prefix="/v1/me", tags=["me"])


@router.get("")
async def me(user_id: str = Depends(current_user_id)):
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, display_name, created_at FROM users WHERE id = $1", user_id
        )
    if row is None:
        raise HTTPException(status_code=404, detail="user not found")
    return {
        "id": str(row["id"]),
        "display_name": row["display_name"],
        "created_at": row["created_at"].isoformat(),
    }


@router.delete("/data")
async def delete_my_data(user_id: str = Depends(current_user_id)):
    async with get_pool().acquire() as conn:
        async def _del(table: str) -> int:
            tag = await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", user_id)
            return int(tag.split()[-1]) if tag.startswith("DELETE") else 0
        return {
            "metric_samples": await _del("metric_samples"),
            "sessions":       await _del("sessions"),
            "activities":     await _del("activities"),
            "profiles":       await _del("profiles"),
        }
