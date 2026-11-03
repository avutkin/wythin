#!/usr/bin/env python3
"""Render docs/customer-dev/roster.md from the CSV produced by customer-dev-roster.sql.

Usage: customer_dev_roster.py roster.csv > docs/customer-dev/roster.md

KNOWN maps a user-id prefix to the person's file under docs/customer-dev/users/.
Add a line here when a new real person shows up in the "unattributed" section.
"""
import csv
import sys
from datetime import date

# user-id prefix -> (slug, display name, note)
KNOWN = {
    "1d8005a2": ("alex-utkin", "Alex Utkin", "owner, current phone"),
    "1e45bfd3": ("alex-utkin", "Alex Utkin", "owner, id wiped 2026-08-09"),
    "a861e2c1": ("alex-utkin", "Alex Utkin", "probable second device, unconfirmed"),
    "3d5edeac": ("gus-tai", "Gus Tai", ""),
    "877b3412": ("natalia-leroux", "Natalia Leroux", ""),
    "520a7455": ("maxim-sleptsov", "Maxim Sleptsov", ""),
    "44be87fb": ("igor-kamenev", "Igor Kamenev", ""),
    "7744273e": ("mikhail-pavlov", "Mikhail Pavlov", ""),
    "7c455f7e": ("kate-shestak", "Kate Shestak", ""),
    "052497b1": ("valeriya-bobyleva", "Valeriya Bobyleva", ""),
    "d9db4361": ("yulia-skidan", "Yulia Skidan", ""),
    "d0f9424e": ("yuri-vedenin", "Yuri Vedenin", ""),
    "1a11673c": ("alexander-baybarin", "Alexander (Sasha) Baybarin", ""),
    "c4497d4f": ("mike-yang", "Mike Yang", ""),
}

ACTIVE_DAYS = 7
FADING_DAYS = 21


def parse_date(s):
    return date.fromisoformat(s) if s else None


def status(last, today):
    if last is None:
        return "no data"
    age = (today - last).days
    if age <= ACTIVE_DAYS:
        return "active"
    if age <= FADING_DAYS:
        return "fading"
    return "lapsed"


def main(path):
    today = date.today()
    rows = [r for r in csv.DictReader(open(path)) if r.get("id")]
    people, unattributed, noise = [], [], []
    for r in rows:
        last = max(filter(None, [parse_date(r["last_sample"]), parse_date(r["last_event"]),
                                 parse_date(r["last_activity"])]), default=None)
        r["_last"] = last
        r["_status"] = status(last, today)
        prefix = r["id"][:8]
        has_profile = bool(r["email"] or r["first_name"])
        first = min(filter(None, [parse_date(r["first_sample"]), parse_date(r["first_event"]),
                                  parse_date(r["created"])]))
        span = (last - first).days if last else 0
        meaningful = span >= 3 or int(r["active_days"] or 0) >= 2
        if prefix in KNOWN:
            people.append(r)
        elif has_profile or meaningful:
            unattributed.append(r)
        else:
            noise.append(r)

    out = []
    out.append("# Roster: every real Wythin user\n")
    out.append(f"Generated {today.isoformat()} by `tools/customer-dev-roster.sh` from the production database. "
               "Do not edit by hand; edit `KNOWN` in `tools/customer_dev_roster.py` to attribute a row to a person.\n")
    out.append(f"Status: active = seen in the last {ACTIVE_DAYS} days, fading = {ACTIVE_DAYS + 1} to {FADING_DAYS} days, "
               "lapsed = older. \"Sample days\" counts days with Polar H10 metric sync; \"app days\" counts days the app was opened.\n")

    out.append("\n## People\n")
    out.append("| Person | Status | Last seen | First seen | Sample days | App days | Activities | Devices (onboarding) | Goals | Id |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    order = {"active": 0, "fading": 1, "lapsed": 2, "no data": 3}
    people.sort(key=lambda r: (order[r["_status"]], -(r["_last"].toordinal() if r["_last"] else 0)))
    for r in people:
        slug, name, note = KNOWN[r["id"][:8]]
        label = f"[{name}](users/{slug}.md)" + (f" ({note})" if note else "")
        first = min(filter(None, [parse_date(r["first_sample"]), parse_date(r["first_event"]), parse_date(r["created"])]))
        out.append(f"| {label} | {r['_status']} | {r['_last'] or ''} | {first} | {r['sample_days'] or 0} | "
                   f"{r['active_days'] or 0} | {r['activities'] or 0} | {r['devices'].replace(';', ', ')} | "
                   f"{r['goals'].replace(';', ', ')} | `{r['id'][:8]}` |")

    out.append("\n## Unattributed devices with real usage\n")
    out.append("Rows that behave like a person but have no onboarding profile. Match them to a TestFlight tester and add them to `KNOWN`.\n")
    out.append("| Id | Status | Created | Last seen | Sample days | App days | Activities |")
    out.append("|---|---|---|---|---|---|---|")
    unattributed.sort(key=lambda r: -(r["_last"].toordinal() if r["_last"] else 0))
    for r in unattributed:
        out.append(f"| `{r['id'][:8]}` | {r['_status']} | {r['created']} | {r['_last'] or ''} | {r['sample_days'] or 0} | "
                   f"{r['active_days'] or 0} | {r['activities'] or 0} |")

    out.append(f"\n## Noise\n\n{len(noise)} further user rows are simulators, test fixtures, or one-off launches "
               "(one sample or one activity, no profile, never seen again). They are not people.\n")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])
