#!/usr/bin/env python3
"""Profile real overnight Polar H10 captures against the sleep model.

Answers the question the synthetic fixtures cannot: what does a real night
actually look like coming off a chest strap, and what do SleepDetector /
SleepStages / SleepScore make of it?

The thresholds below are copied from Wythin/Metrics/SleepDetector.swift and
must be kept in step with it — this is a preview of the Swift pipeline, not a
second implementation of it.

usage:
    # from the personal-data API (only ever returns the caller's own samples)
    curl -s -H "X-User-ID: $UID" -H "X-API-Key: $KEY" \
         "$BASE/v1/metrics/export?limit=5000" > night.json
    python3 tools/profile_night.py night.json

    # or straight from Postgres
    psql "$DATABASE_URL" -qtAX -F',' -f tools/nights.sql > night.csv
    python3 tools/profile_night.py night.csv
"""
import csv
import json
import statistics
import sys
from datetime import datetime, timedelta

# ── thresholds, mirroring SleepThresholds in Swift ──────────────────────
MAX_GAP_SEC = 20 * 60
MIN_NIGHT_SEC = 3 * 3600
# Relative to the recording's own medians — the published absolutes did not
# survive contact with this app's signal definitions. Kept in step with
# SleepThresholds in Swift.
WAKE_MOTION_MULTIPLE = 3.0
WAKE_HR_RISE = 10.0
IMPOSSIBLE_SLEEP_MOTION = 40.0
MIN_STAGE_RUN_SEC = 180


def parse_ts(v):
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v)
    v = str(v).strip().replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(v)
    except ValueError:
        return datetime.strptime(v[:19], "%Y-%m-%d %H:%M:%S")


def load(path):
    """Accepts the API's JSON envelope, a bare JSON list, or CSV."""
    raw = open(path).read().strip()
    if raw.startswith("{") or raw.startswith("["):
        doc = json.loads(raw)
        rows = doc.get("samples", doc) if isinstance(doc, dict) else doc
    else:
        rows = list(csv.DictReader(raw.splitlines()))

    out = []
    for r in rows:
        ts = r.get("ts") or r.get("timestamp")
        if not ts:
            continue

        def num(*keys):
            for k in keys:
                v = r.get(k)
                if v not in (None, "", "NULL"):
                    try:
                        return float(v)
                    except (TypeError, ValueError):
                        pass
            return None

        out.append({
            "ts": parse_ts(ts),
            "hr": num("mean_bpm", "meanBPM", "hr"),
            "rmssd": num("rmssd"),
            "sdnn": num("sdnn"),
            "lfhf": num("lf_hf", "lfHF"),
            "coherence": num("coherence"),
            "breath": num("breath_bpm", "breathBPM"),
            "motion": num("motion"),
        })
    out.sort(key=lambda x: x["ts"])
    return out


def runs(samples):
    """Split on wall-clock holes — SleepDetector.continuousRuns."""
    result, current = [], []
    for s in samples:
        if current and (s["ts"] - current[-1]["ts"]).total_seconds() > MAX_GAP_SEC:
            result.append(current)
            current = []
        current.append(s)
    if current:
        result.append(current)
    return result


def med(samples, key):
    v = [s[key] for s in samples if s[key] is not None]
    return statistics.median(v) if v else None


def classify(samples):
    """SleepStages.classify, including the run-length smoothing."""
    base = {k: med(samples, k) for k in ("motion", "hr", "coherence", "lfhf", "sdnn")}
    raw = []
    for s in samples:
        wake = False
        if s["motion"] is not None and base["motion"]:
            wake = s["motion"] >= base["motion"] * WAKE_MOTION_MULTIPLE
        if not wake and s["hr"] is not None and base["hr"]:
            wake = s["hr"] >= base["hr"] + WAKE_HR_RISE
        if wake:
            raw.append("wake")
            continue
        votes = 0
        if s["coherence"] is not None and base["coherence"] is not None and s["coherence"] >= base["coherence"]:
            votes += 1
        if s["lfhf"] is not None and base["lfhf"] is not None and s["lfhf"] <= base["lfhf"]:
            votes += 1
        if s["sdnn"] is not None and base["sdnn"] is not None and s["sdnn"] <= base["sdnn"]:
            votes += 1
        raw.append("quiet" if votes >= 2 else "active")

    tick = median_tick(samples) or 30
    for _ in range(4):
        changed = False
        i = 0
        while i < len(raw):
            j = i
            while j + 1 < len(raw) and raw[j + 1] == raw[i]:
                j += 1
            if (j - i + 1) * tick < MIN_STAGE_RUN_SEC:
                nb = raw[i - 1] if i > 0 else (raw[j + 1] if j + 1 < len(raw) else None)
                if nb and nb != raw[i]:
                    for k in range(i, j + 1):
                        raw[k] = nb
                    changed = True
            i = j + 1
        if not changed:
            break
    return raw


def median_tick(samples):
    if len(samples) < 2:
        return None
    deltas = [(b["ts"] - a["ts"]).total_seconds() for a, b in zip(samples, samples[1:])]
    return statistics.median(deltas)


def coverage(samples, field):
    have = sum(1 for s in samples if s[field] is not None)
    return 100.0 * have / len(samples) if samples else 0.0


def report(night):
    first, last = night[0]["ts"], night[-1]["ts"]
    span = (last - first).total_seconds()
    tick = median_tick(night) or 0

    print(f"\n  {first:%a %d %b %H:%M} → {last:%H:%M}   "
          f"{int(span // 3600)}h {int(span % 3600 // 60):02d}m   {len(night)} samples")

    # cadence — the number that decides whether a fixed fetch limit truncates
    deltas = [(b["ts"] - a["ts"]).total_seconds() for a, b in zip(night, night[1:])]
    gaps = [d for d in deltas if d > tick * 3]
    print(f"    cadence      median {tick:.0f}s   "
          f"min {min(deltas):.0f}s   max {max(deltas):.0f}s")
    if gaps:
        total_gap = sum(gaps)
        print(f"    gaps         {len(gaps)} holes > {tick*3:.0f}s, "
              f"{total_gap/60:.0f} min missing ({100*total_gap/span:.0f}% of the night)")
    else:
        print("    gaps         none — continuous capture")

    # channel coverage: what the model can actually use
    print("    coverage     " + "  ".join(
        f"{f} {coverage(night, f):.0f}%"
        for f in ("hr", "rmssd", "sdnn", "lfhf", "coherence", "breath", "motion")))

    # what the stage classifier makes of it
    stages = classify(night)
    counts = {s: stages.count(s) for s in ("wake", "active", "quiet")}
    asleep = counts["active"] + counts["quiet"]
    print(f"    stages       " + "  ".join(
        f"{k} {v*tick/3600:.1f}h ({100*v/len(stages):.0f}%)" for k, v in counts.items()))

    # the autonomic shape — nadir depth and placement drive the score
    hrs = [(s["ts"], s["hr"]) for s in night if s["hr"] is not None]
    if len(hrs) > 10:
        onset = statistics.median([h for _, h in hrs[:max(1, len(hrs)//20)]])
        nadir_ts, nadir = min(hrs, key=lambda p: p[1])
        frac = (nadir_ts - first).total_seconds() / span if span else 0
        print(f"    hr           onset {onset:.0f} → nadir {nadir:.0f} bpm "
              f"(−{onset-nadir:.0f}) at {100*frac:.0f}% of the night, {nadir_ts:%H:%M}")

    # the thing the form-factor research says will bite: overnight completeness
    expected = span / tick if tick else 0
    if expected:
        print(f"    completeness {100*len(night)/expected:.0f}% of expected samples present")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    samples = load(sys.argv[1])
    if not samples:
        sys.exit("no samples parsed — check the export format")

    print(f"loaded {len(samples)} samples  "
          f"{samples[0]['ts']:%Y-%m-%d} → {samples[-1]['ts']:%Y-%m-%d}")

    all_runs = runs(samples)
    nights = [r for r in all_runs
              if (r[-1]["ts"] - r[0]["ts"]).total_seconds() >= MIN_NIGHT_SEC]
    print(f"{len(all_runs)} continuous runs, {len(nights)} long enough to be nights "
          f"(≥{MIN_NIGHT_SEC/3600:.0f}h)")

    trimmed = []
    for n in nights:
        m = med(n, "motion")
        if m is not None and m > IMPOSSIBLE_SLEEP_MOTION:
            continue
        st = classify(n)
        idx = [i for i, v in enumerate(st) if v != "wake"]
        if idx:
            trimmed.append(n[idx[0]:idx[-1] + 1])

    for night in trimmed:
        report(night)

    if not nights:
        print("\n  No run reached the night threshold. Longest run: "
              f"{max((r[-1]['ts']-r[0]['ts']).total_seconds() for r in all_runs)/3600:.1f}h")


if __name__ == "__main__":
    main()
