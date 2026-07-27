"""
Database connection pool and schema helpers.
"""
from __future__ import annotations

import asyncpg
import os
from contextlib import asynccontextmanager

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/justbreathe",
)

_pool: asyncpg.Pool | None = None


async def init_pool() -> None:
    global _pool
    _pool = await asyncpg.create_pool(DATABASE_URL, min_size=2, max_size=10)


async def close_pool() -> None:
    if _pool:
        await _pool.close()


def get_pool() -> asyncpg.Pool:
    assert _pool is not None, "DB pool not initialised"
    return _pool


# ---------------------------------------------------------------------------
# Schema creation (run once on startup or via migration)
# ---------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS users (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    apple_sub    TEXT UNIQUE,
    device_id    TEXT UNIQUE,
    display_name TEXT,
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sessions (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID REFERENCES users(id) ON DELETE CASCADE,
    client_session_id    TEXT UNIQUE,           -- UUID from iOS client
    started_at           TIMESTAMPTZ NOT NULL,
    ended_at             TIMESTAMPTZ,
    best_resonance_bpm   REAL,
    avg_rsa_ms           REAL,
    avg_coherence        REAL,
    notes                TEXT,
    created_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS hrv_samples (
    id          BIGSERIAL PRIMARY KEY,
    session_id  UUID REFERENCES sessions(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL,
    mean_bpm    REAL,
    rmssd       REAL,
    sdnn        REAL,
    pnn50       REAL,
    lf_hf       REAL,
    rsa_ms      REAL,
    rsa_idx     REAL,
    coherence   REAL,
    cbi         REAL,
    breath_bpm  REAL
);

CREATE TABLE IF NOT EXISTS activities (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID REFERENCES users(id) ON DELETE CASCADE,
    client_activity_id TEXT UNIQUE,           -- UUID from iOS ActivityLog
    activity_type      TEXT NOT NULL,
    activity_subtype   TEXT,
    custom_name        TEXT,
    started_at         TIMESTAMPTZ NOT NULL,
    ended_at           TIMESTAMPTZ,
    is_manual          BOOLEAN DEFAULT FALSE,
    impact_score       INT,
    notes              TEXT,
    -- before / during / after grid, mirroring ActivityLog's stored averages
    before_hr     REAL, during_hr     REAL, after_hr     REAL,
    before_rmssd  REAL, during_rmssd  REAL, after_rmssd  REAL,
    before_sdnn   REAL, during_sdnn   REAL, after_sdnn   REAL,
    before_rsa    REAL, during_rsa    REAL, after_rsa    REAL,
    before_vti    REAL, during_vti    REAL, after_vti    REAL,
    before_lfhf   REAL, during_lfhf   REAL, after_lfhf   REAL,
    before_stress REAL, during_stress REAL, after_stress REAL,
    before_rcmse  REAL, during_rcmse  REAL, after_rcmse  REAL,
    before_pip    REAL, during_pip    REAL, after_pip    REAL,
    before_dc     REAL, during_dc     REAL, after_dc     REAL,
    before_dfa1   REAL, during_dfa1   REAL, after_dfa1   REAL,
    created_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS metric_samples (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ts          TIMESTAMPTZ NOT NULL,
    mean_bpm REAL, rmssd REAL, sdnn REAL, pnn50 REAL, lf_hf REAL, rsa_ms REAL,
    coherence REAL, cbi REAL, breath_bpm REAL,
    dfa1 REAL, rcmse REAL, pip REAL, dc REAL, vti REAL,
    PRIMARY KEY (user_id, ts)
);
CREATE INDEX IF NOT EXISTS metric_samples_user_ts ON metric_samples(user_id, ts);

CREATE INDEX IF NOT EXISTS hrv_samples_session_ts ON hrv_samples(session_id, ts);
CREATE INDEX IF NOT EXISTS sessions_user_started   ON sessions(user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS activities_user_started ON activities(user_id, started_at DESC);

CREATE TABLE IF NOT EXISTS api_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_sha256 TEXT UNIQUE NOT NULL,
    name         TEXT,
    scopes       TEXT NOT NULL DEFAULT 'read',
    created_at   TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS api_tokens_user ON api_tokens(user_id) WHERE revoked_at IS NULL;
"""


async def create_schema() -> None:
    async with get_pool().acquire() as conn:
        await conn.execute(SCHEMA_SQL)


async def get_or_create_user(device_id: str) -> str:
    """Return user UUID for a device_id, creating the user row if needed."""
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT id FROM users WHERE device_id = $1", device_id
        )
        if row:
            return str(row["id"])
        row = await conn.fetchrow(
            "INSERT INTO users (device_id) VALUES ($1) RETURNING id", device_id
        )
        return str(row["id"])
