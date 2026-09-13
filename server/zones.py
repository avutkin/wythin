"""Which clock a person lives in, when the phone has not said.

The phone reports its IANA zone with the profile and with each activity —
from build 126 on. Every earlier build is silent, and a dashboard that falls
back to the viewer's own zone shows a Moscow night beginning at two in the
afternoon. The data itself pins the zone to the hour: nights cluster around
the sleeper's local midnight, and app opens go quiet in their small hours.

Resolution order, first hit wins:

1. the profile's zone — the phone, as last synced
2. the newest activity that carried a zone — the phone, when it last recorded
3. inferred from the person's recorded nights (a fixed-offset zone, ±1 h)
4. inferred from when they open the app (same, weaker)

An inferred zone is an `Etc/GMT∓N` name, which Intl and ZoneInfo both
accept, and it is always labelled as inferred: a guess that looks like a
fact is worse than the viewer's own clock.
"""
from __future__ import annotations

import math
from datetime import datetime
from typing import Iterable, Optional

#: Where a night's midpoint sits in local time, on average. Population sleep
#: midpoint centres a little after 03:30, and this app's wearers so far run
#: later still — 04:00 put both of the first real cases (Moscow, Los Angeles)
#: on the right hour where 03:30 missed each by one. The spread between
#: people is about an hour, which is the precision claimed.
SLEEP_MIDPOINT_LOCAL_H = 4.0

#: Fewer nights than this and the estimate is one night's bedtime, not a
#: pattern.
MIN_NIGHTS = 1

#: The quietest six hours of app use are taken as roughly 01:00–07:00 local,
#: centred on 04:00. Needs enough opens spread over enough days to have a
#: shape at all.
USAGE_QUIET_CENTRE_LOCAL_H = 4.0
MIN_USAGE_EVENTS = 40


def _circular_mean_hours(hours: Iterable[float]) -> Optional[float]:
    """Mean of times of day in hours, on the circle — 23:30 and 00:30 average
    to midnight, not to noon."""
    xs = [h for h in hours if h is not None]
    if not xs:
        return None
    s = sum(math.sin(2 * math.pi * h / 24) for h in xs)
    c = sum(math.cos(2 * math.pi * h / 24) for h in xs)
    if abs(s) < 1e-9 and abs(c) < 1e-9:
        return None
    return (math.atan2(s, c) * 24 / (2 * math.pi)) % 24


def _offset_hours(local_h: float, utc_h: float) -> int:
    """The whole-hour UTC offset that maps `utc_h` onto `local_h`."""
    diff = (local_h - utc_h + 12) % 24 - 12
    return int(round(diff))


def offset_from_sleep(midpoints_utc: Iterable[datetime]) -> Optional[int]:
    """UTC offset in whole hours from the midpoints of recorded nights."""
    hours = [m.hour + m.minute / 60 for m in midpoints_utc]
    if len(hours) < MIN_NIGHTS:
        return None
    mean = _circular_mean_hours(hours)
    if mean is None:
        return None
    return _offset_hours(SLEEP_MIDPOINT_LOCAL_H, mean)


def offset_from_usage(opens_utc: Iterable[datetime]) -> Optional[int]:
    """UTC offset in whole hours from when the app is opened: the centre of
    the quietest six-hour window is taken as about 04:00 local."""
    counts = [0] * 24
    n = 0
    for t in opens_utc:
        counts[t.hour] += 1
        n += 1
    if n < MIN_USAGE_EVENTS:
        return None
    totals = [sum(counts[(start + i) % 24] for i in range(6)) for start in range(24)]
    best = min(totals)
    # The quiet trough is usually wider than six hours, so several windows
    # tie at the minimum. Take the middle of the tied run, not the first
    # window found — the first is the trough's edge, an hour or two early.
    ties = sorted(i for i, t in enumerate(totals) if t == best)
    if 0 in ties and 23 in ties:
        ties = sorted(t + 24 if t < 12 else t for t in ties)
    quietest = ties[len(ties) // 2] if len(ties) % 2 else (ties[len(ties) // 2 - 1] + ties[len(ties) // 2]) / 2
    centre = (quietest + 3) % 24
    return _offset_hours(USAGE_QUIET_CENTRE_LOCAL_H, centre)


def from_night_fraction(mid_frac, nights) -> Optional[str]:
    """The users list computes the circular mean of night midpoints in SQL
    (a fraction of the UTC day, possibly negative); this turns it into the
    inferred zone name, or None when there are no nights."""
    if mid_frac is None or not nights:
        return None
    utc_h = (float(mid_frac) % 1.0) * 24
    return etc_zone(_offset_hours(SLEEP_MIDPOINT_LOCAL_H, utc_h))


def etc_zone(offset_hours: int) -> str:
    """The IANA fixed-offset name for a whole-hour offset. Note the sign:
    Etc/GMT-3 is UTC+3."""
    if offset_hours == 0:
        return "Etc/UTC"
    return f"Etc/GMT{'-' if offset_hours > 0 else '+'}{abs(offset_hours)}"


def utc_label(offset_hours: int) -> str:
    return "UTC" if offset_hours == 0 else f"UTC{'+' if offset_hours > 0 else '−'}{abs(offset_hours)}"


async def resolve(conn, user_id) -> dict:
    """{"zone", "source", "inferred"} for one user — see the module docstring
    for the order. `zone` is None only when nothing at all is known."""
    zone = await conn.fetchval("SELECT timezone FROM profiles WHERE user_id = $1", user_id)
    if zone:
        return {"zone": zone, "source": "phone, as last synced", "inferred": False}

    zone = await conn.fetchval(
        """
        SELECT timezone FROM activities
        WHERE user_id = $1 AND timezone IS NOT NULL
        ORDER BY started_at DESC LIMIT 1
        """,
        user_id,
    )
    if zone:
        return {"zone": zone, "source": "phone, when it last recorded", "inferred": False}

    nights = await conn.fetch(
        """
        SELECT started_at + (ended_at - started_at) / 2 AS mid
        FROM activities
        WHERE user_id = $1 AND activity_type = 'Sleep' AND ended_at IS NOT NULL
        ORDER BY started_at DESC LIMIT 60
        """,
        user_id,
    )
    off = offset_from_sleep(r["mid"] for r in nights)
    if off is not None:
        n = len(nights)
        return {"zone": etc_zone(off),
                "source": f"inferred from {n} night{'s' if n != 1 else ''} · ±1h",
                "inferred": True}

    opens = await conn.fetch(
        "SELECT ts FROM usage_events WHERE user_id = $1 AND event_type = 'foreground' ORDER BY ts DESC LIMIT 2000",
        user_id,
    )
    off = offset_from_usage(r["ts"] for r in opens)
    if off is not None:
        return {"zone": etc_zone(off), "source": "inferred from app use · ±1h", "inferred": True}

    return {"zone": None, "source": "", "inferred": False}
