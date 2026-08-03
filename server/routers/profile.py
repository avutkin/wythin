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
            "(user_id, first_name, last_name, phone, email, age_range, gender, "
            " height_cm, weight_kg, goals, practices, devices, "
            " state_focus, state_anxiety, state_energy, state_sleep_quality, state_stress, "
            " consent_share_team, consent_ai_insights, updated_at) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, "
            "        $13, $14, $15, $16, $17, $18, $19, NOW()) "
            "ON CONFLICT (user_id) DO UPDATE SET "
            "first_name = EXCLUDED.first_name, last_name = EXCLUDED.last_name, "
            "phone = EXCLUDED.phone, email = EXCLUDED.email, age_range = EXCLUDED.age_range, "
            "gender = EXCLUDED.gender, height_cm = EXCLUDED.height_cm, "
            "weight_kg = EXCLUDED.weight_kg, goals = EXCLUDED.goals, "
            "practices = EXCLUDED.practices, devices = EXCLUDED.devices, "
            "state_focus = EXCLUDED.state_focus, state_anxiety = EXCLUDED.state_anxiety, "
            "state_energy = EXCLUDED.state_energy, "
            "state_sleep_quality = EXCLUDED.state_sleep_quality, "
            "state_stress = EXCLUDED.state_stress, "
            "consent_share_team = EXCLUDED.consent_share_team, "
            "consent_ai_insights = EXCLUDED.consent_ai_insights, updated_at = NOW()",
            user_id, body.first_name, body.last_name, body.phone, body.email,
            body.age_range, body.gender, body.height_cm, body.weight_kg,
            body.goals, body.practices, body.devices,
            body.state_focus, body.state_anxiety, body.state_energy,
            body.state_sleep_quality, body.state_stress,
            body.consent_share_team, body.consent_ai_insights,
        )
    return {"status": "saved"}
