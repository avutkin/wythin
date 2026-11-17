"""Additive, isolated PostgreSQL schema; never projects data into legacy tables."""
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS health_installations (
    id UUID PRIMARY KEY,
    credential_hash TEXT UNIQUE NOT NULL,
    cursor_secret TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS health_enrollment_limits (
    bucket TEXT PRIMARY KEY,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    attempts INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS health_connections (
    id UUID PRIMARY KEY,
    installation_id UUID UNIQUE NOT NULL REFERENCES health_installations(id) ON DELETE CASCADE,
    stream_id UUID NOT NULL,
    epoch BIGINT NOT NULL DEFAULT 1,
    sequence BIGINT NOT NULL DEFAULT 0,
    revision BIGINT NOT NULL DEFAULT 0,
    cloud_consent BOOLEAN NOT NULL,
    consent_version TEXT NOT NULL,
    consented_at TIMESTAMPTZ DEFAULT now(),
    last_ack_at TIMESTAMPTZ,
    last_purged_epoch BIGINT
);
ALTER TABLE health_connections ALTER COLUMN consented_at DROP NOT NULL;
CREATE TABLE IF NOT EXISTS health_workouts (
    connection_id UUID NOT NULL REFERENCES health_connections(id) ON DELETE CASCADE,
    external_id UUID NOT NULL,
    activity_id UUID NOT NULL,
    workout JSONB,
    analysis JSONB,
    annotation JSONB,
    deleted BOOLEAN NOT NULL DEFAULT false,
    server_revision BIGINT NOT NULL,
    PRIMARY KEY(connection_id, external_id),
    UNIQUE(connection_id, activity_id)
);
CREATE TABLE IF NOT EXISTS health_samples (
    connection_id UUID NOT NULL REFERENCES health_connections(id) ON DELETE CASCADE,
    external_id UUID NOT NULL,
    parent_id UUID,
    sample JSONB,
    deleted BOOLEAN NOT NULL DEFAULT false,
    stale BOOLEAN NOT NULL DEFAULT false,
    PRIMARY KEY(connection_id, external_id)
);
CREATE INDEX IF NOT EXISTS health_samples_parent ON health_samples(connection_id,parent_id);
CREATE TABLE IF NOT EXISTS health_sample_links (
    connection_id UUID NOT NULL,
    sample_id UUID NOT NULL,
    workout_id UUID NOT NULL,
    PRIMARY KEY(connection_id,sample_id,workout_id),
    FOREIGN KEY(connection_id,sample_id) REFERENCES health_samples(connection_id,external_id) ON DELETE CASCADE,
    FOREIGN KEY(connection_id,workout_id) REFERENCES health_workouts(connection_id,external_id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS health_series (
    connection_id UUID NOT NULL REFERENCES health_connections(id) ON DELETE CASCADE,
    parent_id UUID NOT NULL,
    generation UUID NOT NULL,
    expected_parts INTEGER NOT NULL,
    digest TEXT NOT NULL,
    committed BOOLEAN NOT NULL DEFAULT false,
    PRIMARY KEY(connection_id,parent_id)
);
CREATE TABLE IF NOT EXISTS health_series_parts (
    connection_id UUID NOT NULL,
    parent_id UUID NOT NULL,
    part_index INTEGER NOT NULL,
    samples JSONB NOT NULL,
    PRIMARY KEY(connection_id,parent_id,part_index),
    FOREIGN KEY(connection_id,parent_id) REFERENCES health_series(connection_id,parent_id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS health_batch_ledger (
    connection_id UUID NOT NULL REFERENCES health_connections(id) ON DELETE CASCADE,
    epoch BIGINT NOT NULL,
    batch_id UUID NOT NULL,
    sequence BIGINT NOT NULL,
    payload_hash TEXT NOT NULL,
    response JSONB NOT NULL,
    PRIMARY KEY(connection_id,epoch,batch_id),
    UNIQUE(connection_id,epoch,sequence)
);
CREATE TABLE IF NOT EXISTS health_operation_ledger (
    connection_id UUID NOT NULL REFERENCES health_connections(id) ON DELETE CASCADE,
    epoch BIGINT NOT NULL,
    operation_id UUID NOT NULL,
    payload_hash TEXT NOT NULL,
    PRIMARY KEY(connection_id,epoch,operation_id)
);
CREATE TABLE IF NOT EXISTS health_changes (
    id BIGSERIAL PRIMARY KEY,
    connection_id UUID NOT NULL REFERENCES health_connections(id) ON DELETE CASCADE,
    epoch BIGINT NOT NULL,
    item JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS health_changes_owner_cursor ON health_changes(connection_id,epoch,id);
"""
