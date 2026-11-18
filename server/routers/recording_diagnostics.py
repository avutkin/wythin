"""Privacy-bounded recording reports and support-stage classification."""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Annotated, Literal
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import AwareDatetime, BaseModel, BeforeValidator, ConfigDict, Field, ValidationError

from ..auth import require_recording_diagnostics_key
from ..db import get_pool, get_or_create_user

router = APIRouter(prefix="/v1/recording-diagnostics", tags=["recording-diagnostics"])

_MAX_BODY = 256 * 1024
_MAX_COUNTER = 2**53 - 1
_MAX_REPORTS_PER_USER = 25_000
_AGE_LIMIT_SECONDS = 315_360_000
_UNKNOWN_STAGES = {"sensor": "unknown", "local": "unknown", "delivery": "unknown"}

Counter = Annotated[int, Field(ge=0, le=_MAX_COUNTER)]
Sequence = Annotated[int, Field(ge=1, le=_MAX_COUNTER)]
Seconds = Annotated[float, Field(ge=0, allow_inf_nan=False)]
Age = Annotated[Seconds, Field(le=_AGE_LIMIT_SECONDS)]
ErrorCode = Annotated[int, Field(ge=-(2**31), le=2**31 - 1)]
HTTPStatus = Annotated[int, Field(ge=100, le=599)]
Version = Annotated[str, Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9._ -]+$")]

_DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}T")


def _iso_datetime(value: object) -> datetime:
    # Pydantic also accepts Unix timestamps and numeric strings by default.
    if not isinstance(value, str) or not _DATE_PREFIX.match(value):
        raise ValueError("expected an aware ISO 8601 datetime")
    stamp = datetime.fromisoformat(value)
    if stamp.tzinfo is None:
        raise ValueError("expected a timezone")
    try:
        return stamp.astimezone(timezone.utc)
    except OverflowError as exc:
        raise ValueError("datetime out of range") from exc


Timestamp = Annotated[AwareDatetime, BeforeValidator(_iso_datetime)]


class WireModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Sensor(WireModel):
    central_state: Literal["unknown", "resetting", "unsupported", "unauthorized", "powered_off", "powered_on"]
    connection_state: Literal["idle", "scanning", "connecting", "connected", "disconnected",
                              "standby", "unauthorized", "unsupported"]
    intended: bool
    rr_live: bool
    ecg_live: bool
    acc_live: bool
    generation: Counter
    connection_age_seconds: Age | None = None
    last_rr_at: Timestamp | None = None
    last_ecg_at: Timestamp | None = None
    last_acc_at: Timestamp | None = None
    sensor_contact: bool | None = None
    hr_packets: Counter | None = None
    ecg_packets: Counter | None = None
    acc_packets: Counter | None = None
    rr_intervals: Counter | None = None
    valid_rr_intervals: Counter | None = None
    invalid_packets: Counter | None = None
    error_domain: Literal["core_bluetooth", "pmd", "cocoa", "posix", "other"] | None = None
    error_code: ErrorCode | None = None
    error_at: Timestamp | None = None


class Recording(WireModel):
    computed_count: Counter
    saved_count: Counter
    failed_save_count: Counter
    last_computed_at: Timestamp | None = None
    last_computed_sample_at: Timestamp | None = None
    last_saved_at: Timestamp | None = None
    last_saved_sample_at: Timestamp | None = None
    computed_age_seconds: Age | None = None
    saved_age_seconds: Age | None = None
    rr_active_age_seconds: Age | None = None
    save_error_domain: Literal["cocoa", "sqlite", "other"] | None = None
    save_error_code: ErrorCode | None = None


class Delivery(WireModel):
    state: Literal["unknown", "idle", "uploading", "retrying", "storage_blocked"]
    queued_batches: Counter
    in_flight: Counter
    maximum_attempts: Counter
    pending_samples: Counter | None = None
    oldest_queued_at: Timestamp | None = None
    last_attempt_at: Timestamp | None = None
    last_ack_at: Timestamp | None = None
    last_ack_sample_at: Timestamp | None = None
    last_http_status: HTTPStatus | None = None
    last_error_code: ErrorCode | None = None


class Event(WireModel):
    schema_version: Annotated[int, Field(ge=1, le=1)]
    event_id: UUID
    installation_id: UUID
    launch_id: UUID
    launch_sequence: Sequence
    sequence: Sequence
    observed_at: Timestamp
    uptime_seconds: Seconds
    reason: Literal["launch", "heartbeat", "lifecycle", "state", "save_error", "memory_warning", "termination"]
    app_version: Version
    app_build: Version
    os_version: Version
    phase: Literal["foreground", "background", "inactive", "unknown"]
    sensor: Sensor
    recording: Recording
    delivery: Delivery
    dropped_reports: Counter


class Batch(WireModel):
    events: Annotated[list[Event], Field(min_length=1, max_length=50)]


@router.post("", dependencies=[Depends(require_recording_diagnostics_key)])
async def upload_recording_diagnostics(
    request: Request, x_user_id: str = Header(..., alias="X-User-ID"),
):
    # Count actual streamed bytes, including chunked requests.
    raw = bytearray()
    async for chunk in request.stream():
        if len(raw) + len(chunk) > _MAX_BODY:
            raise HTTPException(status_code=413, detail="recording diagnostics exceeds 256 KiB")
        raw.extend(chunk)
    try:
        batch = Batch.model_validate_json(raw)
    except ValidationError:
        # Validation details can contain the untrusted values this route rejected.
        raise HTTPException(status_code=422, detail="invalid recording diagnostics batch") from None

    accepted = {}
    async with get_pool().acquire() as conn, conn.transaction():
        # Preserve original wire values after validation, including explicit
        # nulls, timestamp strings, and numeric precision.
        try:
            payloads = await conn.fetchval(
                """SELECT ARRAY_AGG(value ORDER BY ordinality)
                   FROM jsonb_array_elements(($1::jsonb)->'events') WITH ORDINALITY""",
                raw.decode("utf-8"),
            )
        except (UnicodeDecodeError, asyncpg.DataError):
            raise HTTPException(status_code=422, detail="invalid recording diagnostics batch") from None

        user_id = await get_or_create_user(x_user_id, conn=conn)
        # Serialize ingestion and count-based pruning per user across workers.
        await conn.fetchval("SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE", user_id)
        for event, payload in zip(batch.events, payloads, strict=True):
            # Hold an existing replay row until commit so global age cleanup
            # cannot remove it between checking the identity and acknowledging it.
            matches = await conn.fetchval(
                """SELECT payload = $3::jsonb FROM recording_diagnostics
                   WHERE user_id = $1 AND event_id = $2 FOR SHARE""",
                user_id, event.event_id, payload,
            )
            if matches is None:
                matches = await conn.fetchval(
                    """INSERT INTO recording_diagnostics
                         (user_id, event_id, installation_id, launch_id, launch_sequence,
                          sequence, observed_at, payload)
                       VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
                       ON CONFLICT DO NOTHING RETURNING TRUE""",
                    user_id, event.event_id, event.installation_id, event.launch_id,
                    event.launch_sequence, event.sequence, event.observed_at, payload,
                )
            if not matches:
                raise HTTPException(status_code=409, detail="conflicting recording diagnostic event")
            accepted[event.event_id] = None

        await prune_user_reports(conn, user_id)

    return {"accepted_ids": list(accepted)}


async def prune_user_reports(conn: asyncpg.Connection, user_id: str) -> None:
    await conn.execute(
        """DELETE FROM recording_diagnostics
           WHERE user_id = $1 AND received_at < NOW() - INTERVAL '14 days'""",
        user_id,
    )
    # Preserve latest-by-sequence snapshots before filling the remaining
    # timeline by receipt. If installs alone exceed the cap, keep the most
    # recently received latest snapshots and evict whole older installations.
    await conn.execute(
        """WITH surplus AS (
               SELECT event_id FROM (
                   SELECT event_id, received_at, ROW_NUMBER() OVER (
                       PARTITION BY installation_id
                       ORDER BY launch_sequence DESC, sequence DESC
                   ) AS installation_rank
                   FROM recording_diagnostics WHERE user_id = $1
               ) ranked
               ORDER BY (installation_rank = 1) DESC, received_at DESC, event_id DESC
               OFFSET $2
           )
           DELETE FROM recording_diagnostics d USING surplus s
           WHERE d.user_id = $1 AND d.event_id = s.event_id""",
        user_id, _MAX_REPORTS_PER_USER,
    )


def _sensor_stage(s: Sensor) -> str:
    if not s.intended:
        return "paused"
    if s.connection_state == "standby":
        return "standby"
    if s.central_state == "powered_off" or s.connection_state == "disconnected":
        return "disconnected"
    if s.connection_state != "connected":
        return "unknown"
    if s.connection_age_seconds is not None and s.connection_age_seconds < 60:
        return "warming"
    if s.rr_live and s.ecg_live:
        return "receiving"
    if s.connection_age_seconds is None:
        return "unknown"
    return "ecg_stalled" if s.rr_live else "rr_stalled"


def _local_stage(s: Sensor, r: Recording) -> str:
    if r.save_error_domain is not None or r.save_error_code is not None:
        return "save_error"
    if r.saved_age_seconds is not None and r.saved_age_seconds <= 60:
        return "recording"
    if not s.intended or s.connection_state != "connected" or s.central_state == "powered_off":
        return "unknown"
    if r.saved_count == 0 and s.connection_age_seconds is not None and s.connection_age_seconds < 60:
        return "warming"
    if not s.rr_live or r.rr_active_age_seconds is None:
        return "unknown"
    if r.rr_active_age_seconds <= 60:
        return "warming"
    if r.saved_count == 0 or r.saved_age_seconds is not None:
        computed_age = r.computed_age_seconds
        return "processing_stalled" if computed_age is None or computed_age > 60 else "save_stalled"
    return "unknown"


def _delivery_stage(d: Delivery, observed_at: datetime) -> str:
    if d.state in {"storage_blocked", "retrying"}:
        return d.state
    pending = d.queued_batches > 0 or bool(d.pending_samples)
    if pending and d.oldest_queued_at is not None:
        if (observed_at - d.oldest_queued_at).total_seconds() > 180:
            return "awaiting_upload"
        return "uploading"
    if d.in_flight > 0 or (pending and d.state == "uploading"):
        return "uploading"
    if not pending and d.pending_samples == 0:
        return "up_to_date"
    return "unknown"


def _classify(event: Event, received_at: datetime, now: datetime) -> tuple[str, dict[str, str]]:
    observed_age = (now - event.observed_at).total_seconds()
    if observed_age < -120:
        return "clock_skew", _UNKNOWN_STAGES
    if observed_age > 180 or (now - received_at).total_seconds() > 180:
        return "stale", _UNKNOWN_STAGES
    return "fresh", {
        "sensor": _sensor_stage(event.sensor),
        "local": _local_stage(event.sensor, event.recording),
        "delivery": _delivery_stage(event.delivery, event.observed_at),
    }


def _snapshot(row: asyncpg.Record) -> dict:
    return {
        **json.loads(row["payload"]),
        "observed_at": row["observed_at"],
        "received_at": row["received_at"],
    }


async def read_user_diagnostics(user_id: UUID) -> dict:
    async with get_pool().acquire() as conn, conn.transaction(isolation="repeatable_read", readonly=True):
        if not await conn.fetchval("SELECT TRUE FROM users WHERE id = $1", user_id):
            raise HTTPException(status_code=404, detail="user not found")
        latest = await conn.fetch(
            """SELECT DISTINCT ON (installation_id)
                      installation_id, observed_at, received_at, payload
               FROM recording_diagnostics
               WHERE user_id = $1 AND received_at >= NOW() - INTERVAL '14 days'
               ORDER BY installation_id DESC, launch_sequence DESC, sequence DESC""",
            user_id,
        )
        recent = await conn.fetch(
            """SELECT observed_at, received_at, payload FROM recording_diagnostics
               WHERE user_id = $1 AND received_at >= NOW() - INTERVAL '14 days'
               ORDER BY received_at DESC, event_id DESC LIMIT 100""",
            user_id,
        )
        metric = await conn.fetchrow(
            """SELECT MAX(ts) AS last_metric_sample_at, MAX(received_at) AS last_metric_received_at
               FROM metric_samples WHERE user_id = $1""", user_id,
        )

    now = datetime.now(timezone.utc)
    installations = []
    for row in latest:
        event = Event.model_validate_json(row["payload"])
        freshness, stages = _classify(event, row["received_at"], now)
        installations.append({
            "installation_id": row["installation_id"],
            "latest": _snapshot(row),
            "stages": stages,
            "freshness": freshness,
        })
    return {
        "as_of": now,
        "installations": installations,
        "recent_events": [_snapshot(row) for row in recent],
        **dict(metric),
    }
