"""The score a restorative session gets in the app, recomputed from the stored
before/during/after window averages so the dashboard prints the same number.

A port of three pieces of the iOS app, kept deliberately literal so the two
can be diffed by eye:

  * `RestorativeScore` (ios/Wythin/Metrics/RestorativeScore.swift) — the
    0–100 score: each metric earns capped credit for its benefit-signed change
    in the during and after phases, and the metrics are averaged.
  * `ActivityMetricDef.rawBenefitDelta` + `Direction.benefit`
    (ios/Wythin/UI/Activities/ActivityMetricsGrid.swift, ActivityMetricStats.swift)
    — which way is "better" for each metric, and the % change on that axis.
  * `ActivityClass.measured` (ios/Wythin/Metrics/ActivityClass.swift) — a
    session whose pulse rose 15 bpm gets the activating model instead, whose
    score is ranked against on-device history and cannot be rebuilt here.

The app never uploads the score itself (only the older signed mean,
`impact_delta_pct`), so this is the only way the dashboard can agree with it.
"""
from __future__ import annotations

from typing import Optional

# ── RestorativeScore ─────────────────────────────────────────────────────

#: A benefit-signed improvement of this size on a metric is full marks.
FULL_MARKS: float = 20.0

#: Fewer than this many metrics with data and the mean is too thin to show.
MINIMUM_METRICS = 3


def _credit(uplift: float) -> float:
    """Credit a single benefit-signed change earns, 0…1. A metric that got
    worse contributes nothing rather than a negative."""
    return min(max(uplift / FULL_MARKS, 0.0), 1.0)


def restorative_score(during: list[Optional[float]], after: list[Optional[float]]) -> Optional[int]:
    """The app's score across both phases. Each metric contributes the mean of
    whichever phases it has, then the metrics are averaged; a metric with no
    reading in either phase is excluded, not counted as zero."""
    per_metric: list[float] = []
    for d, a in zip(during, after):
        phases = [_credit(v) for v in (d, a) if v is not None]
        if phases:
            per_metric.append(sum(phases) / len(phases))
    if len(per_metric) < MINIMUM_METRICS:
        return None
    # Swift's .rounded() is schoolbook (half away from zero); Python's round()
    # is banker's. Match the app.
    mean = sum(per_metric) / len(per_metric) * 100
    return int(mean + 0.5)


def caption(score: int) -> str:
    """Plain-language read of the score, the app's words."""
    if score >= 80:
        return "deeply restorative"
    if score >= 60:
        return "restorative"
    if score >= 40:
        return "settling"
    if score >= 20:
        return "lightly settling"
    return "held steady"


# ── benefit direction per metric ─────────────────────────────────────────

#: Server column stem → ("higher" | "lower" | ("target", t)). The nine the
#: app scores come first, in the app's registry order; the rest are metrics
#: the dashboard charts but the app's score never sees.
DIRECTION: dict[str, object] = {
    "dc":     "higher",
    "rcmse":  "higher",
    "pip":    "lower",
    "dfa1":   ("target", 1.0),
    "stress": "lower",
    "breath": "lower",
    "rsa":    "higher",
    "rmssd":  "higher",
    "hr":     "lower",
    # Not scored by the app.
    "sdnn":   "higher",
    "vti":    "higher",
    "lfhf":   "lower",
}

#: The metrics that reach the app's score, in its order.
APP_METRICS: tuple[str, ...] = ("dc", "rcmse", "pip", "dfa1", "stress", "breath", "rsa", "rmssd", "hr")


def _benefit(key: str, x: float) -> float:
    d = DIRECTION[key]
    if d == "higher":
        return x
    if d == "lower":
        return -x
    return -abs(x - d[1])


def benefit_pct(key: str, current: Optional[float], base: Optional[float]) -> Optional[float]:
    """Benefit-signed % change of `current` vs `base`: positive is better for
    every metric, so a falling pulse arrives as a positive. Unclamped, like
    the per-metric numbers the app prints; the score caps its own credit.
    None when either side is missing or the baseline's benefit is zero."""
    if current is None or base is None:
        return None
    bb = _benefit(key, base)
    if bb == 0:
        return None
    return (_benefit(key, current) - bb) / abs(bb) * 100


# ── which model a session gets ───────────────────────────────────────────

#: Mean heart rate this far above the pre-session level counts as activation.
ACTIVATING_HR_RISE: float = 15.0

_ACTIVATING_TYPES = {"Exercise", "Walk"}


def activity_class(activity_type: Optional[str], before_hr: Optional[float], during_hr: Optional[float]) -> str:
    """'activating' or 'restorative', decided by what the heart did; the type
    only stands in when there is no measurement."""
    if before_hr is not None and during_hr is not None:
        return "activating" if during_hr - before_hr >= ACTIVATING_HR_RISE else "restorative"
    return "activating" if activity_type in _ACTIVATING_TYPES else "restorative"


# ── the card tag ─────────────────────────────────────────────────────────

#: Within this many percent either way the app calls a change "steady".
STEADY_BAND: float = 2.0


def tag_for(pct: Optional[float]) -> Optional[str]:
    """'up' / 'flat' / 'down' for a benefit-signed % change, using the same
    ±2 % band the app's impact caption calls steady."""
    if pct is None:
        return None
    if pct > STEADY_BAND:
        return "up"
    if pct < -STEADY_BAND:
        return "down"
    return "flat"


# ── the block the activity endpoint returns ──────────────────────────────

def impact_for(row) -> dict:
    """Everything the dashboard's activity page needs to agree with the app,
    from one activities row (a mapping with before_/during_/after_ columns).

    Returns::

        {"class": "restorative" | "activating",
         "score": int | None,            # None for activating, or too few metrics
         "caption": str | None,
         "counted": int, "total": 9,     # metrics that reached the score
         "metrics": {key: {"during_pct", "after_pct", "tag", "scored"}}}
    """
    def col(name):
        v = row.get(name) if hasattr(row, "get") else row[name]
        return float(v) if v is not None else None

    metrics: dict[str, dict] = {}
    for key in DIRECTION:
        before, during, after = col(f"before_{key}"), col(f"during_{key}"), col(f"after_{key}")
        d_pct, a_pct = benefit_pct(key, during, before), benefit_pct(key, after, before)
        # The tag reads the held change when there is one, else the shift.
        metrics[key] = {
            "during_pct": d_pct,
            "after_pct":  a_pct,
            "tag":        tag_for(a_pct if a_pct is not None else d_pct),
            "scored":     key in APP_METRICS,
        }

    cls = activity_class(row.get("activity_type") if hasattr(row, "get") else row["activity_type"],
                         col("before_hr"), col("during_hr"))
    during = [metrics[k]["during_pct"] for k in APP_METRICS]
    after = [metrics[k]["after_pct"] for k in APP_METRICS]
    counted = sum(1 for d, a in zip(during, after) if d is not None or a is not None)

    score = restorative_score(during, after) if cls == "restorative" else None
    return {
        "class":   cls,
        "score":   score,
        "caption": caption(score) if score is not None else None,
        "counted": counted,
        "total":   len(APP_METRICS),
        "metrics": metrics,
    }
