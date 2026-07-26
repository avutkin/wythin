"""Personal-access-token issuance. Gated by the shared X-API-Key (app auth);
scoped to the caller's user via the X-User-ID device header."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException

from ..db import get_pool, get_or_create_user
from ..tokens import generate_token
from ..models import TokenCreate, TokenCreated, TokenInfo

router = APIRouter(prefix="/v1/tokens", tags=["tokens"])


@router.post("", response_model=TokenCreated)
async def create_token(body: TokenCreate, x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    raw, token_hash = generate_token()
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "INSERT INTO api_tokens (user_id, token_sha256, name) "
            "VALUES ($1, $2, $3) RETURNING id, name, created_at",
            user_id, token_hash, body.name,
        )
    return TokenCreated(token=raw, id=str(row["id"]), name=row["name"],
                        created_at=row["created_at"].isoformat())


@router.get("", response_model=list[TokenInfo])
async def list_tokens(x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    async with get_pool().acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, name, created_at, last_used_at FROM api_tokens "
            "WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at DESC",
            user_id,
        )
    return [
        TokenInfo(
            id=str(r["id"]), name=r["name"],
            created_at=r["created_at"].isoformat(),
            last_used_at=r["last_used_at"].isoformat() if r["last_used_at"] else None,
        )
        for r in rows
    ]


@router.delete("/{token_id}")
async def revoke_token(token_id: str, x_user_id: str = Header(..., alias="X-User-ID")):
    user_id = await get_or_create_user(x_user_id)
    async with get_pool().acquire() as conn:
        res = await conn.execute(
            "UPDATE api_tokens SET revoked_at = NOW() "
            "WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
            token_id, user_id,
        )
    if res == "UPDATE 0":
        raise HTTPException(status_code=404, detail="token not found")
    return {"status": "revoked"}
