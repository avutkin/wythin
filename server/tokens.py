"""Personal-access-token generation and hashing."""
from __future__ import annotations

import hashlib
import secrets

TOKEN_PREFIX = "wyth_pat_"


def hash_token(raw: str) -> str:
    """Hex SHA-256 of a raw token — the only form we store."""
    return hashlib.sha256(raw.encode()).hexdigest()


def generate_token() -> tuple[str, str]:
    """Return (raw_token, sha256_hex). Raw is shown to the user once."""
    raw = TOKEN_PREFIX + secrets.token_urlsafe(32)
    return raw, hash_token(raw)
