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
    # Pin the session timezone to UTC so timestamp handling never depends on the
    # host's timezone: naive datetimes and date_trunc()/::date bucketing all
    # resolve in UTC, matching the tz-aware UTC values the app uploads. Keeps the
    # data anchored to its own timestamps even if the box's tz ever changes.
    _pool = await asyncpg.create_pool(DATABASE_URL, min_size=2, max_size=10,
                                      server_settings={"timezone": "UTC"})


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
    impact_delta_pct   REAL,
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
    before_breath REAL, during_breath REAL, after_breath REAL,
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

-- Full onboarding profile, incl. contact info, for the admin dashboard.
CREATE TABLE IF NOT EXISTS profiles (
    user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    first_name TEXT,
    last_name  TEXT,
    phone      TEXT,
    email      TEXT,
    age_range  TEXT,
    gender     TEXT,
    height_cm  INT,
    weight_kg  INT,
    goals      TEXT[],
    practices  TEXT[],
    devices    TEXT[],
    -- Self-reported onboarding baseline, 0-10 each, NULL where skipped.
    state_focus         INT,
    state_anxiety       INT,
    state_energy        INT,
    state_sleep_quality INT,
    state_stress        INT,
    -- Data-sharing consent; absence of an answer is never agreement.
    consent_share_team  BOOLEAN NOT NULL DEFAULT FALSE,
    consent_ai_insights BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

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

CREATE TABLE IF NOT EXISTS usage_events (
    id               BIGSERIAL PRIMARY KEY,
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type       TEXT NOT NULL,          -- 'foreground' | 'ecg_recording'
    ts               TIMESTAMPTZ NOT NULL,   -- when the interval started
    duration_ms      BIGINT,                 -- interval length in ms
    client_event_id  TEXT UNIQUE,            -- iOS-generated UUID → idempotent upload
    created_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS usage_events_user_ts ON usage_events(user_id, ts);

-- Additive migrations. SCHEMA_SQL runs on every boot, and each statement here
-- is idempotent, so this block is safe to re-run and safe to grow. Columns
-- added to a CREATE TABLE body above only reach a database that does not yet
-- exist; existing deployments need them stated here as well.
ALTER TABLE activities ADD COLUMN IF NOT EXISTS impact_delta_pct REAL;
-- Breath Rate, the ninth named metric, added once it earned a tile of its own.
ALTER TABLE activities ADD COLUMN IF NOT EXISTS before_breath REAL;
ALTER TABLE activities ADD COLUMN IF NOT EXISTS during_breath REAL;
ALTER TABLE activities ADD COLUMN IF NOT EXISTS after_breath  REAL;

-- Onboarding v2: name, body metrics and the self-reported baseline.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS first_name          TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS last_name           TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS height_cm           INT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS weight_kg           INT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS state_focus         INT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS state_anxiety       INT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS state_energy        INT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS state_sleep_quality INT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS state_stress        INT;

-- Data-sharing consent. NOT NULL DEFAULT FALSE so an existing row that predates
-- the question is treated as "has not consented" rather than NULL, which a
-- careless `WHERE consent_ai_insights IS NOT FALSE` would let through.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS consent_share_team  BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS consent_ai_insights BOOLEAN NOT NULL DEFAULT FALSE;
"""


async def create_schema() -> None:
    async with get_pool().acquire() as conn:
        await conn.execute(SCHEMA_SQL)


async def has_ai_insights_consent(device_id: str) -> bool:
    """True only if this device's profile carries an explicit AI-sharing consent.

    Deliberately never creates a user: asking whether someone consented must not
    be the act that brings them into existence. A device with no profile row has
    not answered the question, and an unanswered question is not a yes — so both
    "no such user" and "no profile" return False.
    """
    async with get_pool().acquire() as conn:
        row = await conn.fetchrow(
            "SELECT p.consent_ai_insights "
            "FROM profiles p JOIN users u ON u.id = p.user_id "
            "WHERE u.device_id = $1",
            device_id,
        )
    return bool(row and row["consent_ai_insights"])


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
