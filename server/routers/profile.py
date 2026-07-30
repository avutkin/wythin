"""POST /v1/profile — upload the iOS onboarding profile (goals, practices,
devices, contact/basic details). Shared-key gated; scoped to the caller's user
via X-User-ID. One row per user (upsert)."""
from __future__ import annotations

from fastapi import APIRouter, Header

from ..db import get_pool, get_or_create_user
from ..models import ProfileUpload

router = APIRouter(prefix="/v1/profile", tags=["profile"])


@router.post("")
async def save_profile(body: ProfileUpload, x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    async with get_pool().acquire() as conn:
        await conn.execute(
            "INSERT INTO profiles "
            "(user_id, phone, email, age_range, gender, goals, practices, devices, updated_at) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW()) "
            "ON CONFLICT (user_id) DO UPDATE SET "
            "phone = EXCLUDED.phone, email = EXCLUDED.email, age_range = EXCLUDED.age_range, "
            "gender = EXCLUDED.gender, goals = EXCLUDED.goals, practices = EXCLUDED.practices, "
            "devices = EXCLUDED.devices, updated_at = NOW()",
            user_id, body.phone, body.email, body.age_range, body.gender,
            body.goals, body.practices, body.devices,
        )
    return {"status": "saved"}
