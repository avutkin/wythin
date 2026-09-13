"""A phone that never said its zone still gets the person's clock, to the
hour, from where their nights and app opens fall. Pure; no database."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from server.zones import offset_from_sleep, offset_from_usage, etc_zone, utc_label


def _utc(h, m=0):
    return datetime(2026, 9, 7, h, m, tzinfo=timezone.utc)


def test_a_moscow_sleeper_reads_as_plus_three():
    # Maxim's real nights: 21:55 → 05:01 UTC, midpoint 01:28 UTC, 04:28 in UTC+3.
    mids = [_utc(1, 28), _utc(1, 45), _utc(1, 5), _utc(1, 20)]
    assert offset_from_sleep(mids) == 3


def test_a_los_angeles_sleeper_reads_as_minus_seven():
    # Gus's real night: 07:07 → 15:11 UTC, midpoint 11:09 UTC, 04:09 in UTC−7.
    assert offset_from_sleep([_utc(11, 9), _utc(11, 30), _utc(10, 50)]) == -7


def test_midpoints_either_side_of_midnight_utc_average_on_the_circle():
    # 23:40 and 00:20 UTC average to midnight, not to noon: UTC+4.
    assert offset_from_sleep([_utc(23, 40), _utc(0, 20)]) == 4


def test_a_jakarta_sleeper_reads_as_plus_seven():
    # 04:00 local = 21:00 UTC the previous evening.
    assert offset_from_sleep([_utc(21, 0), _utc(21, 15)]) == 7


def test_no_nights_no_guess():
    assert offset_from_sleep([]) is None


def test_app_opens_place_the_quiet_hours():
    # Someone in UTC+3 who opens the app between 08:00 and 23:00 local, i.e.
    # 05:00–20:00 UTC, and never between 01:00 and 07:00 local (22:00–04:00 UTC).
    opens = []
    day = datetime(2026, 9, 1, tzinfo=timezone.utc)
    for d in range(10):
        for h in range(5, 21):
            opens.append(day + timedelta(days=d, hours=h, minutes=7))
    assert offset_from_usage(opens) == 3


def test_too_few_opens_is_no_guess():
    assert offset_from_usage([_utc(9)] * 10) is None


def test_etc_zone_sign_is_the_posix_one():
    assert etc_zone(3) == "Etc/GMT-3"
    assert etc_zone(-7) == "Etc/GMT+7"
    assert etc_zone(0) == "Etc/UTC"
    assert utc_label(3) == "UTC+3" and utc_label(-7) == "UTC−7"


def test_inferred_zones_are_names_intl_and_zoneinfo_accept():
    from zoneinfo import ZoneInfo
    for off in (-11, -7, 0, 1, 3, 7, 9, 13):
        ZoneInfo(etc_zone(off))
