"""Read-only, per-user endpoint scoped by the Bearer token's user_id.
The seed of the /v1/me/* API (SP2 expands it)."""
from __future__ import annotations

import os
from fastapi import APIRouter, Depends, HTTPException
from .raw import lock_archive_user
from .. import archive_store
from starlette.concurrency import run_in_threadpool

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
    async with get_pool().acquire() as conn, conn.transaction():
        await lock_archive_user(conn, user_id)
        backends = {r["storage_backend"] for r in await conn.fetch(
            "SELECT DISTINCT storage_backend FROM raw_chunks WHERE user_id=$1", user_id)}
        if os.getenv("RAW_ARCHIVE_ROOT") or os.getenv("RAW_ARCHIVE_BACKEND") == "s3":
            backends.add(os.getenv("RAW_ARCHIVE_BACKEND", "filesystem"))
        for backend in sorted(backends):
            archive = archive_store.get_archive(backend)
            await run_in_threadpool(archive.delete_user, user_id)
        async def _del(table: str) -> int:
            tag = await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", user_id)
            return int(tag.split()[-1]) if tag.startswith("DELETE") else 0
        return {
            "metric_samples": await _del("metric_samples"),
            "sessions":       await _del("sessions"),
            "activities":     await _del("activities"),
            "profiles":       await _del("profiles"),
            "raw_chunks":     await _del("raw_chunks"),
            "usage_events":   await _del("usage_events"),
            "felt_state_logs": await _del("felt_state_logs"),
        }
