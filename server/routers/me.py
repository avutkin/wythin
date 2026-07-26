"""Read-only, per-user endpoint scoped by the Bearer token's user_id.
The seed of the /v1/me/* API (SP2 expands it)."""
from __future__ import annotations

from fastapi import APIRouter, Depends

from ..db import get_pool
from ..auth_user import current_user_id

router = APIRouter(prefix="/v1/me", tags=["me"])


@router.get("")
async def me(user_id: str = Depends(current_user_id)):
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id, display_name, created_at FROM users WHERE id = $1", user_id
        )
    return {
        "id": str(row["id"]),
        "display_name": row["display_name"],
        "created_at": row["created_at"].isoformat(),
    }
