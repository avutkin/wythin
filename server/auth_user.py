"""Bearer personal-access-token authentication → user_id, with a simple
in-memory per-token rate limiter."""
from __future__ import annotations

import time
from typing import Optional

from fastapi import Header, HTTPException

from .db import get_pool
from .tokens import hash_token, TOKEN_PREFIX

_RATE_LIMIT = 120          # requests
_WINDOW = 60.0             # seconds
_hits: dict[str, tuple[float, int]] = {}


def _allow(key: str) -> bool:
    now = time.monotonic()
    start, count = _hits.get(key, (now, 0))
    if now - start >= _WINDOW:
        _hits[key] = (now, 1)
        return True
    if count >= _RATE_LIMIT:
        return False
    _hits[key] = (start, count + 1)
    return True


async def current_user_id(authorization: Optional[str] = Header(default=None)) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    raw = authorization[len("Bearer "):].strip()
    if not raw.startswith(TOKEN_PREFIX):
        raise HTTPException(status_code=401, detail="invalid token")
    token_hash = hash_token(raw)
    if not _allow(token_hash):
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT user_id, revoked_at FROM api_tokens WHERE token_sha256 = $1",
            token_hash,
        )
        if row is None or row["revoked_at"] is not None:
            raise HTTPException(status_code=401, detail="invalid or revoked token")
        await conn.execute(
            "UPDATE api_tokens SET last_used_at = NOW() WHERE token_sha256 = $1",
            token_hash,
        )
    return str(row["user_id"])
