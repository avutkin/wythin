"""Health credentials are independent of API_KEY, public device IDs and PATs."""
from hashlib import sha256
import re

from fastapi import Header, HTTPException
from ..db import get_pool

TOKEN_RE = re.compile(r'^whi_[A-Za-z0-9_-]{43}$')


async def installation(authorization: str | None = Header(default=None)):
    if not authorization or not authorization.startswith('Bearer '):
        raise HTTPException(401, 'health credential required')
    token = authorization[7:]
    if not TOKEN_RE.fullmatch(token):
        raise HTTPException(401, 'invalid health credential')
    row = await get_pool().fetchrow('SELECT id,cursor_secret FROM health_installations WHERE credential_hash=$1', sha256(token.encode()).hexdigest())
    if row is None:
        raise HTTPException(401, 'invalid health credential')
    return row
