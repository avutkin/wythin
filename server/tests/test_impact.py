"""The dashboard's Impact tile must print the number the app prints.

Every case here is a port of ios/WythinTests/RestorativeScoreTests.swift (and
the benefit-direction rules in ActivityMetricsGrid.swift), so a divergence
between the two scorers shows up as a red test rather than as two dashboards
disagreeing about the same sit. Pure — no database.
"""
from __future__ import annotations

from server.impact import (
    FULL_MARKS, APP_METRICS, benefit_pct, restorative_score, caption,
    activity_class, impact_for, tag_for,
)


def nine(v):
    return [v] * 9


# ── RestorativeScore.score ────────────────────────────────────────────────

def test_stronger_improvements_score_higher():
    scores = [restorative_score(nine(v), nine(None)) for v in (2, 6, 10, 16, 20)]
    assert scores == sorted(scores)


def test_full_marks_on_every_metric_scores_one_hundred():
    assert restorative_score(nine(FULL_MARKS), nine(None)) == 100


def test_beyond_full_marks_does_not_overflow():
    assert restorative_score(nine(400), nine(None)) == 100


def test_half_of_full_marks_scores_about_half():
    assert abs(restorative_score(nine(10), nine(None)) - 50) <= 1


def test_a_session_that_changed_nothing_scores_zero():
    assert restorative_score(nine(0), nine(None)) == 0


def test_regressions_contribute_nothing_rather_than_negative():
    mixed = [20, 20, 20, 20, 20, 20, 20, 20, -500]
    assert abs(restorative_score(mixed, nine(None)) - 89) <= 1


def test_absent_metrics_are_excluded_not_counted_as_zero():
    partial = [20, 20, 20, None, None, None, None, None, None]
    assert restorative_score(partial, nine(None)) == 100


def test_too_few_metrics_yields_no_score():
    assert restorative_score([20, 20] + [None] * 7, nine(None)) is None
    assert restorative_score(nine(None), nine(None)) is None


def test_a_shift_that_held_outscores_one_that_evaporated():
    assert restorative_score(nine(20), nine(20)) == 100
    assert restorative_score(nine(20), nine(0)) == 50


def test_gains_arriving_only_after_still_count():
    assert restorative_score(nine(0), nine(20)) == 50


def test_a_metric_measured_in_one_phase_is_not_half_weighted():
    assert restorative_score([20, 20, 20], [20, None, None]) == 100


def test_a_metric_with_no_reading_in_either_phase_is_excluded():
    assert restorative_score([20, 20, 20, None], [20, 20, 20, None]) == 100


def test_too_few_measured_metrics_still_yields_no_score():
    assert restorative_score([20, None, None], [None, None, None]) is None


def test_captions_rise_with_the_score():
    assert caption(85) == "deeply restorative"
    assert caption(60) == "restorative"
    assert caption(45) == "settling"
    assert caption(25) == "lightly settling"
    assert caption(5) == "held steady"


# ── benefit-signed % change, one metric ──────────────────────────────────

def test_lower_is_better_metrics_flip_sign():
    # Pulse 65 → 62 is a 4.6 % improvement, not a 4.6 % drop.
    assert benefit_pct("hr", 62, 65) > 0
    assert round(benefit_pct("hr", 62, 65), 1) == 4.6


def test_higher_is_better_metrics_keep_sign():
    assert round(benefit_pct("rsa", 33, 12), 0) == 175


def test_harmony_is_scored_against_its_target_not_upward():
    # DFA α1 has a target of 1.0: moving from 0.8 to 1.0 is better, moving
    # from 1.0 to 1.2 is worse, even though both are "up".
    assert benefit_pct("dfa1", 1.0, 0.8) > 0
    assert benefit_pct("dfa1", 1.2, 1.0) is None or benefit_pct("dfa1", 1.2, 1.0) < 0


def test_missing_or_zero_baseline_is_undefined():
    assert benefit_pct("hr", 62, None) is None
    assert benefit_pct("hr", None, 65) is None
    assert benefit_pct("rmssd", 30, 0) is None


def test_the_app_scores_exactly_nine_metrics():
    assert len(APP_METRICS) == 9
    assert set(APP_METRICS) == {"dc", "rcmse", "pip", "dfa1", "stress", "breath", "rsa", "rmssd", "hr"}


# ── which model a session gets ───────────────────────────────────────────

def test_a_pulse_rise_of_fifteen_makes_it_activating():
    assert activity_class("Meditation", 60, 75) == "activating"
    assert activity_class("Meditation", 60, 74) == "restorative"


def test_without_a_measurement_the_type_stands_in():
    assert activity_class("Exercise", None, None) == "activating"
    assert activity_class("Walk", None, None) == "activating"
    assert activity_class("Meditation", None, None) == "restorative"
    assert activity_class("Custom", None, None) == "restorative"


# ── the tag on each card ─────────────────────────────────────────────────

def test_tag_colours_follow_the_apps_steady_band():
    assert tag_for(8.0) == "up"
    assert tag_for(2.0) == "flat"
    assert tag_for(-2.0) == "flat"
    assert tag_for(-8.0) == "down"
    assert tag_for(None) is None


# ── the whole block the endpoint returns ─────────────────────────────────

def _row(**kw):
    base = {"activity_type": "Meditation"}
    base.update(kw)
    return base


def test_impact_for_scores_a_restorative_sit():
    row = _row(before_hr=65, during_hr=63, after_hr=62,
               before_rsa=12, during_rsa=38, after_rsa=33,
               before_rmssd=15, during_rmssd=19, after_rmssd=20)
    imp = impact_for(row)
    assert imp["class"] == "restorative"
    assert imp["counted"] == 3 and imp["total"] == 9
    # HR: during +3.1, after +4.6 → credits .15, .23 → .19
    # RSA: +217, +175 → capped 1, 1 → 1
    # RMSSD: +26.7, +33 → capped 1, 1 → 1
    assert imp["score"] == 73
    assert imp["caption"] == "restorative"
    assert imp["metrics"]["hr"]["scored"] is True
    assert round(imp["metrics"]["hr"]["after_pct"], 1) == 4.6
    assert imp["metrics"]["hr"]["tag"] == "up"


def test_impact_for_leaves_activating_sessions_unscored():
    row = _row(activity_type="Exercise", before_hr=60, during_hr=140, after_hr=80,
               before_rsa=12, during_rsa=8, before_rmssd=30, during_rmssd=10)
    imp = impact_for(row)
    assert imp["class"] == "activating"
    assert imp["score"] is None
    # The per-metric percentages are still there for the cards.
    assert imp["metrics"]["hr"]["during_pct"] < 0
    assert imp["metrics"]["hr"]["tag"] == "down"


def test_impact_for_reports_unscored_metrics_too():
    # SDNN, VTI and LF/HF are on the dashboard but not in the app's score.
    row = _row(before_sdnn=67, during_sdnn=57, after_sdnn=51)
    imp = impact_for(row)
    assert imp["metrics"]["sdnn"]["scored"] is False
    assert round(imp["metrics"]["sdnn"]["after_pct"], 0) == -24
    assert imp["score"] is None  # nothing scorable → too few metrics
