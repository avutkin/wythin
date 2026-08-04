"""
GET /admin/dashboard       — self-contained HTML user-activity dashboard
GET /admin/stats           — aggregate usage stats (KPIs, sessions/day, per-user)
GET /admin/users           — list all users + last-seen
GET /admin/users/{id}      — per-user summary + their session list
GET /admin/sessions        — all sessions (recent)
GET /admin/sessions/{id}/samples — per-tick series for charts (JSON)
GET /admin/sessions/{id}/export  — CSV download
"""
from __future__ import annotations

import csv
import io
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse, HTMLResponse
from ..db import get_pool
from ..models import AdminUserRow

router = APIRouter(prefix="/admin", tags=["admin"])

# A *session* is the chest strap being live for at least a minute. The app
# records that as one `ecg_recording` usage event (connect→disconnect, with
# duration_ms = wear time) — see routers/usage.py. The legacy `sessions` table
# is written only by the old /sessions upload path, which no shipping client
# calls, so every session figure below comes from usage_events.
_SESSION_MIN_MS = 60_000

_RANGES = ("today", "24h", "7d", "30d", "90d", "all")


def _range_window(rng: str, off: timedelta) -> tuple[datetime | None, str]:
    """(since, bucket) for a picker range; `since` of None means all time.

    `off` is the viewer's UTC offset as JS reports it (minutes to add to local
    time to reach UTC), so "today" is their calendar day rather than UTC's —
    at 8am in UTC-7 those differ by a whole morning of practice."""
    now = datetime.now(timezone.utc)
    if rng == "today":
        midnight_local = (now - off).replace(hour=0, minute=0, second=0, microsecond=0)
        return midnight_local + off, "hour"
    if rng == "24h":
        return now - timedelta(hours=24), "hour"
    if rng == "7d":
        return now - timedelta(days=7), "day"
    if rng == "30d":
        return now - timedelta(days=30), "day"
    if rng == "all":
        return None, "day"
    return now - timedelta(days=90), "day"

# Loaded once at import. The page itself carries NO data — it fetches /admin/stats
# with the X-API-Key header — so serving the shell without the key gate is safe.
_DASHBOARD_HTML = (
    Path(__file__).resolve().parent.parent / "templates" / "dashboard.html"
).read_text(encoding="utf-8")


@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard_page() -> HTMLResponse:
    # The page carries its own JS, so without this browsers heuristically cache
    # it and keep running a previous deploy's dashboard against the new API —
    # which looks exactly like the deploy not having happened.
    return HTMLResponse(_DASHBOARD_HTML, headers={"Cache-Control": "no-store, must-revalidate"})


@router.get("/stats")
async def usage_stats(
    range_: str = Query("90d", alias="range"),
    tz_offset: int = 0,
    days: int | None = None,
):
    """Aggregate usage over the selected range: headline KPIs, a sessions-per-
    bucket series, and a per-user activity table.

    A session is one strap recording of at least a minute; practice minutes are
    that strap time. Everything except TOTAL USERS (all-time, the denominator)
    is scoped to `range` — one of today / 24h / 7d / 30d / 90d / all. `tz_offset`
    is the viewer's JS timezone offset in minutes so day boundaries are theirs.
    `days=N` is still honoured as a rolling N-day window for older links."""
    tz_offset = max(-900, min(tz_offset, 900))
    off = timedelta(minutes=tz_offset)
    if days is not None:
        days = max(1, min(days, 3650))
        label, bucket = f"{days}d", "day"
        since = datetime.now(timezone.utc) - timedelta(days=days)
    else:
        label = range_ if range_ in _RANGES else "90d"
        since, bucket = _range_window(label, off)
    today_local: date = (datetime.now(timezone.utc) - off).date()

    pool = get_pool()
    async with pool.acquire() as conn:
        kpi = await conn.fetchrow(
            """
            WITH sess AS (
                SELECT user_id, duration_ms
                FROM usage_events
                WHERE event_type = 'ecg_recording' AND duration_ms >= $1
                  AND ($2::timestamptz IS NULL OR ts >= $2)
            )
            SELECT
              (SELECT COUNT(*) FROM users)                                AS total_users,
              (SELECT COUNT(DISTINCT user_id) FROM sess)                  AS active_users,
              (SELECT COUNT(*) FROM sess)                                 AS total_sessions,
              (SELECT COALESCE(SUM(duration_ms), 0) / 60000.0 FROM sess)  AS total_minutes,
              (SELECT COALESCE(AVG(duration_ms), 0) / 60000.0 FROM sess)  AS avg_session_min
            """,
            _SESSION_MIN_MS, since,
        )
        series = await conn.fetch(
            f"""
            SELECT date_trunc('{bucket}', ts - $3::interval) + $3::interval AS bucket,
                   COUNT(*) AS sessions
            FROM usage_events
            WHERE event_type = 'ecg_recording' AND duration_ms >= $1
              AND ($2::timestamptz IS NULL OR ts >= $2)
            GROUP BY 1
            ORDER BY 1
            """,
            _SESSION_MIN_MS, since, off,
        )
        users = await conn.fetch(
            """
            WITH sess AS (
                SELECT user_id, ts, duration_ms
                FROM usage_events
                WHERE event_type = 'ecg_recording' AND duration_ms >= $1
            ),
            in_range AS (
                SELECT user_id,
                       COUNT(*)                        AS session_count,
                       SUM(duration_ms) / 60000.0      AS total_minutes
                FROM sess
                WHERE ($2::timestamptz IS NULL OR ts >= $2)
                GROUP BY user_id
            ),
            -- "Last seen" means the newest PolarH10 data: a strap recording or
            -- a strap-derived metric sample. Opening the app or typing in a
            -- manual activity is not the sensor seeing you.
            seen AS (
                SELECT user_id, MAX(ts) AS last_seen FROM (
                    SELECT user_id, ts FROM usage_events WHERE event_type = 'ecg_recording'
                    UNION ALL
                    -- Only samples that actually measured something. A row of
                    -- nulls is a timestamp, not a reading, and letting it count
                    -- put "last strap" hours past the last real measurement.
                    SELECT user_id, ts FROM metric_samples
                     WHERE num_nonnulls(mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms,
                                        coherence, cbi, breath_bpm, dfa1, rcmse,
                                        pip, dc, vti) > 0
                ) x
                GROUP BY user_id
            ),
            -- Any sign of life, strap or not. Drives the range filter, so a
            -- user who opened the app but never strapped up still shows up
            -- (with an empty last_seen) rather than vanishing.
            signal AS (
                SELECT user_id, MAX(ts) AS last_signal FROM (
                    SELECT user_id, ts                             FROM usage_events
                    UNION ALL
                    SELECT user_id, COALESCE(ended_at, started_at) FROM activities
                    UNION ALL
                    SELECT user_id, ts                             FROM metric_samples
                    UNION ALL
                    SELECT user_id, COALESCE(ended_at, started_at) FROM sessions
                ) x
                GROUP BY user_id
            ),
            metrics AS (
                SELECT user_id, AVG(coherence) AS avg_coherence, AVG(rsa_ms) AS avg_rsa
                FROM metric_samples
                WHERE ($2::timestamptz IS NULL OR ts >= $2)
                GROUP BY user_id
            ),
            practice_days AS (
                SELECT DISTINCT user_id, (ts_day)::date AS d FROM (
                    SELECT user_id, date_trunc('day', ts - $3::interval) AS ts_day FROM sess
                    UNION ALL
                    SELECT user_id, date_trunc('day', started_at - $3::interval) AS ts_day FROM activities
                ) x
            ),
            islands AS (
                SELECT user_id, d,
                       d - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d))::int AS grp
                FROM practice_days
            ),
            streaks AS (
                SELECT user_id, COUNT(*) AS len, MAX(d) AS last_day
                FROM islands GROUP BY user_id, grp
            ),
            consistency AS (
                SELECT
                    pd.user_id,
                    COALESCE(MAX(s.len) FILTER (WHERE s.last_day >= $4::date - 1), 0) AS current_streak,
                    COUNT(DISTINCT pd.d) FILTER (WHERE pd.d > $4::date - 7)           AS days_active_7d,
                    BOOL_OR(pd.d = $4::date)                                          AS practiced_today
                FROM practice_days pd
                LEFT JOIN streaks s ON s.user_id = pd.user_id
                GROUP BY pd.user_id
            ),
            usage_agg AS (
                SELECT user_id,
                    COUNT(*) FILTER (WHERE event_type = 'foreground')                                AS opens_total,
                    COALESCE(SUM(duration_ms) FILTER (WHERE event_type = 'foreground'), 0) / 60000.0  AS active_min_total,
                    COUNT(*) FILTER (WHERE event_type = 'ecg_recording')                             AS ecg_total,
                    GREATEST(COUNT(DISTINCT date_trunc('day', ts - $3::interval)), 1)                AS usage_days
                FROM usage_events GROUP BY user_id
            )
            SELECT
              u.id, u.device_id, u.display_name,
              u.created_at                       AS first_seen,
              sn.last_seen                       AS last_seen,
              sg.last_signal                     AS last_signal,
              COALESCE(ir.session_count, 0)      AS session_count,
              COALESCE(ir.total_minutes, 0)      AS total_minutes,
              m.avg_coherence                    AS avg_coherence,
              m.avg_rsa                          AS avg_rsa,
              COALESCE(c.current_streak, 0)      AS current_streak,
              COALESCE(c.days_active_7d, 0)      AS days_active_7d,
              COALESCE(c.practiced_today, FALSE) AS practiced_today,
              COALESCE(ua.opens_total::float / ua.usage_days, 0)  AS avg_opens_day,
              COALESCE(ua.active_min_total / ua.usage_days, 0)    AS avg_active_min_day,
              COALESCE(ua.ecg_total::float / ua.usage_days, 0)    AS avg_ecg_day,
              -- What they told onboarding they're optimising for.
              COALESCE(pr.goals, '{}')                            AS goals,
              COALESCE(pr.practices, '{}')                        AS practices
            FROM users u
            LEFT JOIN profiles pr   ON pr.user_id = u.id
            LEFT JOIN in_range ir   ON ir.user_id = u.id
            LEFT JOIN seen sn       ON sn.user_id = u.id
            LEFT JOIN signal sg     ON sg.user_id = u.id
            LEFT JOIN metrics m     ON m.user_id  = u.id
            LEFT JOIN consistency c ON c.user_id  = u.id
            LEFT JOIN usage_agg ua  ON ua.user_id = u.id
            -- Only users active within the range — judged on any signal, not
            -- just strap data, so app-only users stay visible. "All time"
            -- ($2 IS NULL) keeps the full roster, including dormant accounts.
            WHERE $2::timestamptz IS NULL OR sg.last_signal >= $2
            ORDER BY COALESCE(sn.last_seen, sg.last_signal) DESC NULLS LAST
            """,
            _SESSION_MIN_MS, since, off, today_local,
        )

    def _f(v):
        return float(v) if v is not None else None

    _streaks = sorted(r["current_streak"] for r in users)
    if _streaks:
        _mid = len(_streaks) // 2
        median_streak = float(
            _streaks[_mid] if len(_streaks) % 2 else (_streaks[_mid - 1] + _streaks[_mid]) / 2
        )
    else:
        median_streak = 0.0

    return {
        "range":  label,
        "bucket": bucket,
        "since":  since.isoformat() if since else None,
        "kpis": {
            "total_users":     kpi["total_users"],
            "active_users":    kpi["active_users"],
            "total_sessions":  kpi["total_sessions"],
            "total_minutes":   round(_f(kpi["total_minutes"]), 1),
            "avg_session_min": round(_f(kpi["avg_session_min"]), 1),
            "median_streak":   round(median_streak, 1),
        },
        "sessions_per_day": [
            {"t": r["bucket"].isoformat(), "sessions": r["sessions"]} for r in series
        ],
        "users": [
            {
                "id":            str(r["id"]),
                "device_id":     r["device_id"],
                "display_name":  r["display_name"],
                "first_seen":    r["first_seen"].isoformat() if r["first_seen"] else None,
                "last_seen":     r["last_seen"].isoformat() if r["last_seen"] else None,
                "last_signal":   r["last_signal"].isoformat() if r["last_signal"] else None,
                "session_count": r["session_count"],
                "total_minutes": round(_f(r["total_minutes"]), 1),
                "avg_coherence": round(_f(r["avg_coherence"]), 3) if r["avg_coherence"] is not None else None,
                "avg_rsa":       round(_f(r["avg_rsa"]), 1) if r["avg_rsa"] is not None else None,
                "current_streak":  r["current_streak"],
                "days_active_7d":  r["days_active_7d"],
                "practiced_today": r["practiced_today"],
                "avg_opens_day":      round(_f(r["avg_opens_day"]), 1),
                "avg_active_min_day": round(_f(r["avg_active_min_day"]), 1),
                "avg_ecg_day":        round(_f(r["avg_ecg_day"]), 1),
                "goals":              list(r["goals"] or []),
                "practices":          list(r["practices"] or []),
            }
            for r in users
        ],
    }


def _activity_row(r) -> dict:
    """asyncpg activities Record → JSON-safe dict (all columns, incl. the full
    before/during/after metric grid)."""
    d = dict(r)
    d["id"] = str(d["id"])
    d.pop("user_id", None)
    for k in ("started_at", "ended_at", "created_at"):
        if d.get(k) is not None:
            d[k] = d[k].isoformat()
    return d


@router.get("/users/{user_id}")
async def user_detail(user_id: str):
    """One user's summary KPIs plus their full session list (newest first).
    Feeds the dashboard's per-user drill-down."""
    pool = get_pool()
    async with pool.acquire() as conn:
        # Same session definition as /admin/stats: strap recordings of at least
        # a minute, all-time for this user.
        u = await conn.fetchrow(
            """
            SELECT
              u.id, u.device_id, u.display_name,
              u.created_at AS first_seen,
              -- Newest PolarH10 data, same definition as the user table.
              (SELECT MAX(ts) FROM (
                   SELECT ts FROM usage_events e
                     WHERE e.user_id = u.id AND e.event_type = 'ecg_recording'
                   UNION ALL
                   SELECT ts FROM metric_samples m WHERE m.user_id = u.id
                     AND num_nonnulls(m.mean_bpm, m.rmssd, m.sdnn, m.pnn50, m.lf_hf,
                                      m.rsa_ms, m.coherence, m.cbi, m.breath_bpm,
                                      m.dfa1, m.rcmse, m.pip, m.dc, m.vti) > 0
               ) s) AS last_seen,
              (SELECT COUNT(*) FROM usage_events e
                 WHERE e.user_id = u.id AND e.event_type = 'ecg_recording'
                   AND e.duration_ms >= $2)                                AS session_count,
              (SELECT COALESCE(SUM(duration_ms), 0) / 60000.0 FROM usage_events e
                 WHERE e.user_id = u.id AND e.event_type = 'ecg_recording'
                   AND e.duration_ms >= $2)                                AS total_minutes,
              (SELECT AVG(coherence) FROM metric_samples m WHERE m.user_id = u.id) AS avg_coherence,
              (SELECT AVG(rsa_ms)    FROM metric_samples m WHERE m.user_id = u.id) AS avg_rsa
            FROM users u
            WHERE u.id = $1::uuid
            """,
            user_id, _SESSION_MIN_MS,
        )
        if u is None:
            raise HTTPException(status_code=404, detail="user not found")
        sessions = await conn.fetch(
            """
            SELECT
              s.id, s.started_at, s.ended_at,
              s.avg_rsa_ms, s.avg_coherence, s.best_resonance_bpm,
              (SELECT COUNT(*) FROM hrv_samples h WHERE h.session_id = s.id) AS sample_count
            FROM sessions s
            WHERE s.user_id = $1::uuid
            ORDER BY s.started_at DESC
            """,
            user_id,
        )
        activities = await conn.fetch(
            """
            SELECT * FROM activities
            WHERE user_id = $1::uuid
            ORDER BY started_at DESC
            """,
            user_id,
        )
        # Everything they answered at onboarding, contact details included.
        profile = await conn.fetchrow(
            """
            SELECT first_name, last_name, phone, email, age_range, gender,
                   height_cm, weight_kg, goals, practices, devices,
                   state_focus, state_anxiety, state_energy,
                   state_sleep_quality, state_stress,
                   consent_share_team, consent_ai_insights, updated_at
            FROM profiles WHERE user_id = $1::uuid
            """,
            user_id,
        )

    def _f(v):
        return float(v) if v is not None else None

    def _dur(a, b):
        return round((b - a).total_seconds() / 60.0, 1) if a and b else None

    return {
        "user": {
            "id":            str(u["id"]),
            "device_id":     u["device_id"],
            "display_name":  u["display_name"],
            "first_seen":    u["first_seen"].isoformat() if u["first_seen"] else None,
            "last_seen":     u["last_seen"].isoformat() if u["last_seen"] else None,
            "session_count": u["session_count"],
            "total_minutes": round(_f(u["total_minutes"]), 1),
            "avg_coherence": round(_f(u["avg_coherence"]), 3) if u["avg_coherence"] is not None else None,
            "avg_rsa":       round(_f(u["avg_rsa"]), 1) if u["avg_rsa"] is not None else None,
        },
        "sessions": [
            {
                "id":                 str(r["id"]),
                "started_at":         r["started_at"].isoformat() if r["started_at"] else None,
                "ended_at":           r["ended_at"].isoformat() if r["ended_at"] else None,
                "duration_min":       _dur(r["started_at"], r["ended_at"]),
                "avg_rsa_ms":         _f(r["avg_rsa_ms"]),
                "avg_coherence":      _f(r["avg_coherence"]),
                "best_resonance_bpm": _f(r["best_resonance_bpm"]),
                "sample_count":       r["sample_count"],
            }
            for r in sessions
        ],
        "activities": [_activity_row(r) for r in activities],
        "profile": None if profile is None else {
            "first_name": profile["first_name"],
            "last_name":  profile["last_name"],
            "phone":      profile["phone"],
            "email":      profile["email"],
            "age_range":  profile["age_range"],
            "gender":     profile["gender"],
            "height_cm":  profile["height_cm"],
            "weight_kg":  profile["weight_kg"],
            "goals":      list(profile["goals"] or []),
            "practices":  list(profile["practices"] or []),
            "devices":    list(profile["devices"] or []),
            # Self-reported baseline from onboarding, 0-10, null where skipped.
            # Kept as a nested object so a coach reading this can tell the
            # subjective answers from the measured ones at a glance.
            "current_state": {
                "focus":         profile["state_focus"],
                "anxiety":       profile["state_anxiety"],
                "energy":        profile["state_energy"],
                "sleep_quality": profile["state_sleep_quality"],
                "stress":        profile["state_stress"],
            },
            "consent": {
                "share_team":  profile["consent_share_team"],
                "ai_insights": profile["consent_ai_insights"],
            },
            "updated_at": profile["updated_at"].isoformat() if profile["updated_at"] else None,
        },
    }


_METRIC_WINDOWS = {
    "24h": (timedelta(hours=24), timedelta(minutes=5)),
    "7d":  (timedelta(days=7),   timedelta(hours=1)),
    "30d": (timedelta(days=30),  timedelta(hours=4)),
}
_METRIC_COLS = ("mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf", "rsa_ms",
                "coherence", "cbi", "breath_bpm", "dfa1", "rcmse", "pip", "dc", "vti")


@router.get("/users/{user_id}/metrics")
async def user_metrics(user_id: str, window: str = "24h", offset: int = 0):
    """Bucketed per-user metric_samples series for the live charts. `window` is
    one of 24h / 7d / 30d; each column is averaged per time bucket.

    `offset` steps backwards a whole window at a time — offset=1 is the window
    before the current one — so yesterday is reachable without a date picker."""
    window = window if window in _METRIC_WINDOWS else "24h"
    span, bucket = _METRIC_WINDOWS[window]
    offset = max(0, min(offset, 3650))
    end = datetime.now(timezone.utc) - span * offset
    start = end - span
    avg_cols = ", ".join(f"AVG({c}) AS {c}" for c in _METRIC_COLS)
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            f"""
            SELECT date_bin($2::interval, ts, TIMESTAMPTZ 'epoch') AS bucket, {avg_cols}
            FROM metric_samples
            WHERE user_id = $1::uuid AND ts > $3 AND ts <= $4
            GROUP BY bucket
            ORDER BY bucket
            """,
            user_id, bucket, start, end,
        )

    def _f(v):
        return float(v) if v is not None else None

    return {
        "window": window,
        "offset": offset,
        "start":  start.isoformat(),
        "end":    end.isoformat(),
        "samples": [
            {"ts": r["bucket"].isoformat(), **{c: _f(r[c]) for c in _METRIC_COLS}}
            for r in rows
        ],
    }


# ── Track: daily averages per metric, the way the app's Track screen reads ──
#
# Mirrors ios/Wythin/Metrics: one bar per bucket, a personal baseline from the
# 90-day median of daily averages (needing 14 days before it stops being a
# fixed norm), and a benefit-signed delta against the immediately prior period.
_TRACK_BASELINE_DAYS = 90
_TRACK_MIN_BASELINE_DAYS = 14

# period -> (bucket, count) where bucket is 'day', 'week' or 'month'.
_TRACK_PERIODS = {
    "week":      ("day", 7),
    "halfmonth": ("day", 15),
    "month":     ("day", 30),
    "sixweek":   ("week", 6),
    "sixmonth":  ("month", 6),
}

# Benefit direction, from ActivityMetricsGrid.swift. Metrics the app has no
# stated direction for are reported as None: bars and averages still make
# sense, "better than typical" does not.
_TRACK_DIRECTION = {
    "mean_bpm": "lower",  "rmssd": "higher", "rsa_ms": "higher", "vti": "higher",
    "dc": "higher",       "rcmse": "higher", "pip": "lower",     "lf_hf": "lower",
    "dfa1": "target",     "coherence": "higher",
    "sdnn": None, "pnn50": None, "cbi": None, "breath_bpm": None,
}
_TRACK_TARGET = {"dfa1": 1.0}


@router.get("/users/{user_id}/track")
async def user_track(user_id: str, period: str = "week", offset: int = 0,
                     tz_offset: int = 0):
    """Per-metric daily averages over a period, with the baseline and the
    period-over-period delta the app's Track screen shows.

    `offset` pages backwards whole periods. `tz_offset` is the viewer's JS
    timezone offset so days break on their midnight, not UTC's."""
    period = period if period in _TRACK_PERIODS else "week"
    bucket, count = _TRACK_PERIODS[period]
    offset = max(0, min(offset, 120))
    tz_offset = max(-900, min(tz_offset, 900))
    off = timedelta(minutes=tz_offset)

    # Work in the viewer's local calendar, then shift back to UTC for the query.
    local_today = (datetime.now(timezone.utc) - off).replace(
        hour=0, minute=0, second=0, microsecond=0)
    if bucket == "day":
        end_local = local_today + timedelta(days=1) - timedelta(days=count * offset)
        start_local = end_local - timedelta(days=count)
    elif bucket == "week":
        end_local = local_today + timedelta(days=1) - timedelta(weeks=count * offset)
        start_local = end_local - timedelta(weeks=count)
    else:  # month — anchored to the first of the month, like the app's 6M page
        first = local_today.replace(day=1)
        months_back = count * offset
        y, m = first.year, first.month - months_back
        while m <= 0:
            m += 12
            y -= 1
        end_local = _add_months(datetime(y, m, 1, tzinfo=timezone.utc), 1)
        start_local = _add_months(end_local, -count)

    prior_start_local = start_local - (end_local - start_local)
    baseline_start_local = end_local - timedelta(days=_TRACK_BASELINE_DAYS)
    # One pass over every day that any part of the response needs.
    query_from = min(prior_start_local, baseline_start_local)

    avg_cols = ", ".join(f"AVG({c}) AS {c}" for c in _METRIC_COLS)
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            f"""
            SELECT (date_trunc('day', ts - $2::interval))::date AS day, {avg_cols}
            FROM metric_samples
            WHERE user_id = $1::uuid AND ts >= $3 AND ts < $4
            GROUP BY day
            ORDER BY day
            """,
            user_id, off, query_from + off, end_local + off,
        )

    daily = {r["day"]: r for r in rows}
    buckets = _track_buckets(bucket, start_local, end_local, count)
    prior_buckets = _track_buckets(bucket, prior_start_local, start_local, count)

    def mean(values):
        vals = [v for v in values if v is not None]
        return sum(vals) / len(vals) if vals else None

    def bucket_value(col, b_start, b_end):
        return mean([daily[d][col] for d in daily if b_start <= d < b_end])

    metrics = []
    for col in _METRIC_COLS:
        bars = [{"label": label, "start": b_start.isoformat(),
                 "value": bucket_value(col, b_start, b_end)}
                for label, b_start, b_end in buckets]
        present = [b["value"] for b in bars if b["value"] is not None]
        average = sum(present) / len(present) if present else None

        prior = [bucket_value(col, s, e) for _, s, e in prior_buckets]
        prior_present = [v for v in prior if v is not None]
        prior_avg = sum(prior_present) / len(prior_present) if prior_present else None

        direction = _TRACK_DIRECTION.get(col)
        delta = None
        if average is not None and prior_avg not in (None, 0):
            raw = (average - prior_avg) / abs(prior_avg) * 100.0
            # Benefit-signed: positive always means "better".
            if direction == "lower":
                raw = -raw
            elif direction == "target":
                target = _TRACK_TARGET.get(col, 1.0)
                raw = (abs(prior_avg - target) - abs(average - target)) / abs(prior_avg) * 100.0
            delta = round(raw, 1)

        # Baseline: the median of this person's own daily averages over the
        # trailing 90 days, once there are enough of them.
        window = sorted(v for d, r in daily.items()
                        if baseline_start_local.date() <= d < end_local.date()
                        for v in [r[col]] if v is not None)
        reference, personal = None, False
        if len(window) >= _TRACK_MIN_BASELINE_DAYS:
            mid = len(window) // 2
            reference = (window[mid] if len(window) % 2
                         else (window[mid - 1] + window[mid]) / 2)
            personal = True

        better = None
        if reference is not None and direction in ("higher", "lower", "target"):
            if direction == "higher":
                better = sum(1 for v in present if v > reference)
            elif direction == "lower":
                better = sum(1 for v in present if v < reference)
            else:
                target = _TRACK_TARGET.get(col, 1.0)
                better = sum(1 for v in present if abs(v - target) < abs(reference - target))

        metrics.append({
            "key": col,
            "bars": [{**b, "value": round(b["value"], 3) if b["value"] is not None else None}
                     for b in bars],
            "average": round(average, 3) if average is not None else None,
            "delta_pct": delta,
            "direction": direction,
            "reference": round(reference, 3) if reference is not None else None,
            "reference_is_personal": personal,
            "better_count": better,
            "present_count": len(present),
        })

    return {
        "period": period,
        "offset": offset,
        "bucket": bucket,
        "start": start_local.isoformat(),
        "end": end_local.isoformat(),
        "metrics": metrics,
    }


def _add_months(d: datetime, n: int) -> datetime:
    y, m = d.year, d.month + n
    while m > 12:
        m -= 12
        y += 1
    while m <= 0:
        m += 12
        y -= 1
    return d.replace(year=y, month=m, day=1)


def _track_buckets(bucket: str, start: datetime, end: datetime, count: int):
    """(label, start_date, end_date) per bar, in the viewer's calendar."""
    out = []
    if bucket == "day":
        d = start
        while d < end:
            nxt = d + timedelta(days=1)
            label = d.strftime("%-d") if count > 7 else d.strftime("%a")[0] + " " + d.strftime("%-m/%-d")
            out.append((label, d.date(), nxt.date()))
            d = nxt
    elif bucket == "week":
        d = start
        while d < end:
            nxt = d + timedelta(weeks=1)
            out.append((d.strftime("%-m/%-d"), d.date(), nxt.date()))
            d = nxt
    else:
        d = start
        while d < end:
            nxt = _add_months(d, 1)
            out.append((d.strftime("%b"), d.date(), nxt.date()))
            d = nxt
    return out


@router.get("/activities/{activity_id}")
async def activity_detail(activity_id: str):
    """One activity's full before/during/after metric grid + impact score."""
    pool = get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT * FROM activities WHERE id = $1::uuid", activity_id
        )
    if row is None:
        raise HTTPException(status_code=404, detail="activity not found")
    return _activity_row(row)


@router.get("/users/{user_id}/usage")
async def user_usage(user_id: str, days: int = 30):
    """Per-day app-usage series for one user: opens, active minutes, ECG
    recordings and ECG minutes — plus per-active-day averages."""
    days = max(1, min(days, 730))
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
              date_trunc('day', ts)::date AS day,
              COUNT(*) FILTER (WHERE event_type = 'foreground')                                    AS opens,
              COALESCE(SUM(duration_ms) FILTER (WHERE event_type = 'foreground'), 0) / 60000.0      AS active_min,
              COUNT(*) FILTER (WHERE event_type = 'ecg_recording')                                 AS ecg_recordings,
              COALESCE(SUM(duration_ms) FILTER (WHERE event_type = 'ecg_recording'), 0) / 60000.0   AS ecg_min
            FROM usage_events
            WHERE user_id = $1::uuid AND ts > NOW() - ($2::int * INTERVAL '1 day')
            GROUP BY day
            ORDER BY day
            """,
            user_id, days,
        )
    series = [
        {"day": r["day"].isoformat(), "opens": r["opens"],
         "active_min": round(float(r["active_min"]), 1),
         "ecg_recordings": r["ecg_recordings"],
         "ecg_min": round(float(r["ecg_min"]), 1)}
        for r in rows
    ]
    n = len(series) or 1
    return {
        "days": days,
        "series": series,
        "averages": {
            "opens_day":      round(sum(s["opens"] for s in series) / n, 1),
            "active_min_day": round(sum(s["active_min"] for s in series) / n, 1),
            "ecg_day":        round(sum(s["ecg_recordings"] for s in series) / n, 1),
        },
    }


@router.get("/sessions/{session_id}/samples")
async def session_samples(session_id: str):
    """Per-tick metric series for one session — the same signals the app charts
    (HR, HRV/RMSSD, RSA, coherence, breath)."""
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT ts, mean_bpm, rmssd, sdnn, rsa_ms, coherence, breath_bpm, lf_hf
            FROM hrv_samples
            WHERE session_id = $1::uuid
            ORDER BY ts
            """,
            session_id,
        )
    return {
        "session_id": session_id,
        "samples": [
            {
                "ts":         r["ts"].isoformat(),
                "mean_bpm":   r["mean_bpm"],
                "rmssd":      r["rmssd"],
                "sdnn":       r["sdnn"],
                "rsa_ms":     r["rsa_ms"],
                "coherence":  r["coherence"],
                "breath_bpm": r["breath_bpm"],
                "lf_hf":      r["lf_hf"],
            }
            for r in rows
        ],
    }


@router.get("/users", response_model=list[AdminUserRow])
async def list_users():
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                u.id,
                u.device_id,
                MAX(s.started_at) AS last_seen,
                COUNT(s.id)       AS session_count
            FROM users u
            LEFT JOIN sessions s ON s.user_id = u.id
            GROUP BY u.id
            ORDER BY last_seen DESC NULLS LAST
            """
        )
    return [
        AdminUserRow(
            id=str(r["id"]),
            device_id=r["device_id"],
            last_seen=r["last_seen"].isoformat() if r["last_seen"] else None,
            session_count=r["session_count"],
        )
        for r in rows
    ]


@router.get("/sessions")
async def list_all_sessions(limit: int = 100):
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                s.id, s.started_at, s.ended_at,
                s.avg_rsa_ms, s.avg_coherence,
                u.device_id
            FROM sessions s
            JOIN users u ON u.id = s.user_id
            ORDER BY s.started_at DESC
            LIMIT $1
            """,
            limit,
        )
    return [
        {
            "id":            str(r["id"]),
            "started_at":    r["started_at"].isoformat(),
            "ended_at":      r["ended_at"].isoformat() if r["ended_at"] else None,
            "avg_rsa_ms":    r["avg_rsa_ms"],
            "avg_coherence": r["avg_coherence"],
            "device_id":     r["device_id"],
        }
        for r in rows
    ]


@router.get("/sessions/{session_id}/export")
async def export_session_csv(session_id: str):
    """Download all hrv_samples for a session as CSV."""
    pool = get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT ts, mean_bpm, rmssd, sdnn, pnn50, lf_hf,
                   rsa_ms, rsa_idx, coherence, cbi, breath_bpm
            FROM hrv_samples
            WHERE session_id = $1::uuid
            ORDER BY ts
            """,
            session_id,
        )

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(["ts", "mean_bpm", "rmssd", "sdnn", "pnn50", "lf_hf",
                     "rsa_ms", "rsa_idx", "coherence", "cbi", "breath_bpm"])
    for r in rows:
        writer.writerow([
            r["ts"].isoformat(),
            r["mean_bpm"], r["rmssd"], r["sdnn"], r["pnn50"], r["lf_hf"],
            r["rsa_ms"], r["rsa_idx"], r["coherence"], r["cbi"], r["breath_bpm"],
        ])

    buf.seek(0)
    return StreamingResponse(
        iter([buf.read()]),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename=session_{session_id[:8]}.csv"},
    )
