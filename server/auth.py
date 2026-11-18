"""API key checks for the optional global gate and the required diagnostics gate."""
from __future__ import annotations

import os
from secrets import compare_digest

from fastapi import Header, HTTPException

API_KEY = os.getenv("API_KEY")


def key_ok(provided: str | None) -> bool:
    """True if the gate is disabled, or the provided key matches."""
    return (not API_KEY) or provided == API_KEY


async def require_recording_diagnostics_key(x_api_key: str | None = Header(None, alias="X-API-Key")) -> None:
    """Require a configured key even on deployments with the global gate disabled."""
    expected = API_KEY or os.getenv("RECORDING_DIAGNOSTICS_API_KEY")
    if not expected:
        raise HTTPException(status_code=503, detail="recording diagnostics unavailable")
    if x_api_key is None or not compare_digest(x_api_key.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="unauthorized")
