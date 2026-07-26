from __future__ import annotations

from server.tokens import generate_token, hash_token, TOKEN_PREFIX


def test_generate_token_shape_and_hash():
    raw, h = generate_token()
    assert raw.startswith(TOKEN_PREFIX)
    assert len(raw) > len(TOKEN_PREFIX) + 20
    assert h == hash_token(raw)
    assert len(h) == 64                    # sha256 hex
    # Uniqueness across calls
    raw2, h2 = generate_token()
    assert raw != raw2 and h != h2
