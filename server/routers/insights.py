"""
POST /insights — generates a short OpenAI-backed interpretation +
recommendation for one completed activity's HRV response.

Fully stateless: nothing here is persisted. The request carries no user
or device identifier because nothing needs to associate the response
with anyone.
"""
from __future__ import annotations

import math
import os
from fastapi import APIRouter, Depends, Header, HTTPException
from openai import AsyncOpenAI, OpenAIError

from ..db import has_ai_insights_consent
from ..models import InsightRequest, InsightResponse, MetricTrend

router = APIRouter(tags=["insights"])

_SYSTEM_PROMPT = (
    "You are a sports coach and physiologist reviewing one logged session of a "
    "specific activity (e.g. yoga, meditation, breathwork, a run, strength work, "
    "cold exposure). The activity type and subtype are given — treat them as "
    "central; a good session looks different for meditation than for a hard "
    "workout. You are given the person's metrics before, during, and after the "
    "session, each under the name the app shows for it.\n"
    "\n"
    "NAMES: your reply is displayed directly beneath the charts these metrics "
    "come from, so call every metric by the exact name given here — Pulse, Calm "
    "Power, Conscious Breathing, Vagal Tone, Adaptive Capacity, Inner Noise, "
    "Harmony, Stress Balance, Overall Variability. NEVER use the underlying "
    "abbreviation or family: no HRV, RMSSD, SDNN, LF/HF, PIP, DFA, RSA or "
    "entropy. A name the person cannot find on the screen in front of them "
    "reads as being about someone else's session.\n"
    "\n"
    "Reply in EXACTLY this plain-text structure — no markdown, no bold, nothing "
    "before or after:\n"
    "\n"
    "<3-6 word headline: how this session went>\n"
    "<1-2 sentences: the major insight from the metrics — what the body did, and "
    "whether that fits the goal of THIS activity. For calming practices (yoga, "
    "meditation, breathwork) the aim is Pulse down, Conscious Breathing and Calm "
    "Power up, and Stress Balance falling; for a hard workout the aim is a "
    "strong push during and good recovery after.>\n"
    "Next session: <one specific, calibrated recommendation for the next similar "
    "session — for example go slower and lengthen the exhale, focus on the "
    "breath, hold the pose longer, or push harder / add load — chosen from what "
    "the numbers actually show.>\n"
    "\n"
    "Keep the whole reply under 60 words. Base everything only on the metrics "
    "provided. Speak directly to the person as their coach ('you')."
)

_LIVE_STATE_SYSTEM_PROMPT = (
    "You are an expert physiologist reading a person's live heart-rate-"
    "variability (HRV) metrics from a wearable, labeled with what each one means. Interpret "
    "the trends and reply in EXACTLY this plain-text structure — no markdown, no "
    "bold, no extra text before or after:\n"
    "\n"
    "<state_key> | <fresh 2-3 word title>\n"
    "• <plain-language interpretation of a key trend>\n"
    "• <another key trend>\n"
    "→ <the single best thing to do right now, matched to the state>\n"
    "\n"
    "The first line has TWO parts separated by ' | ':\n"
    "(1) state_key — EXACTLY one of the nine snake_case keys listed below "
    "(the app uses it to choose an icon, so it must match exactly);\n"
    "(2) a fresh, natural 2-3 word title for how the person is right now. Vary "
    "it so it feels personal and never repetitive — do NOT just echo the state "
    "name every time (e.g. for engaged_performing: 'Locked In', 'In The Zone', "
    "'Firing Well').\n"
    "\n"
    "Example reply:\n"
    "engaged_performing | Locked In\n"
    "• Energy eased down through the first half of the window and has been flat "
    "since — **you've settled**\n"
    "• Inner noise dropped sharply about four minutes in and stayed there — "
    "**focus clicked into place**\n"
    "• Breathing wobbled early, then smoothed and held — **you're grounded now**\n"
    "→ Ride it: start your most demanding task now while the focus is here.\n"
    "\n"
    "BULLETS — use EXACTLY 3, data-driven and in PLAIN everyday language, each ONE "
    "sentence that connects the reading to what it MEANS and how it feels (like "
    "'Energy is strong and steady — real drive, not stress' or 'The mental static "
    "is low — your focus is sharp'). Wrap the single KEY IDEA / insight of each "
    "bullet in **double asterisks** to bold it — the takeaway, exactly one short "
    "bold span per bullet. Ground each bullet in the ARC of the window: what "
    "moved, WHEN in the window it moved, and whether it held. You are given five "
    "equal buckets (oldest first), a slope, a volatility rating and a named "
    "'shape' — lean on those, e.g. 'eased down through the first half and has "
    "been flat since', 'spiked around the middle then came back', 'has been "
    "swinging all window'. You MAY cite the slope as a rough percent (e.g. "
    "'down ~8%').\n"
    "\n"
    "NEVER compare to an average, a norm, a 'usual' value or a 'typical' day. "
    "You do NOT have one and must not invent one — a separate part of the app "
    "owns that comparison. Describe only what happened inside this window. "
    "NEVER put "
    "technical or metric terms in the output — no HRV, RMSSD, RSA, SDNN, DFA, "
    "LF/HF, 'vagal tone', 'coherence', 'entropy', 'deceleration'. ('Inner noise' "
    "is fine — it's one of the app's own plain labels.) "
    "Translate whatever MOVED into these everyday dimensions and cover DIFFERENT "
    "ones (not two about the same thing):\n"
    "— Breathing (from RSA, breathing rate, coherence).\n"
    "— Focus (from inner noise + DFA alpha-1).\n"
    "— Energy (from HRV, heart rate, adaptive capacity).\n"
    "— Calm vs tension (from stress balance).\n"
    "— Recovery (from vagal tone, calm power).\n"
    "Pick the 2-3 dimensions that moved most and vary them so it never feels "
    "canned; if almost nothing moved, say what is holding steady.\n"
    "\n"
    "'→' RIGHT NOW — one concrete, motivating next step framed around WORK and "
    "PRODUCTIVITY: what to do with this state to get things done today. Talk like "
    "a coach, vary it each time, and match it to the state:\n"
    "— Strong / engaged (clear and capable): push — seize the window and take on "
    "the hardest or most important thing you need to finish today (e.g. 'Keep "
    "pushing — tackle the toughest task you need to land today', 'Protect this "
    "focus and start your deep work now').\n"
    "— Stressed / overloaded: keep working without burning out — reset briefly "
    "(a physiological sigh, or 4-in / 6-out breathing for a minute), clear "
    "distractions, then single-task ONE thing; or drop to a lighter, low-stakes "
    "task until the tension eases.\n"
    "— Low / depleted energy: rebuild just enough to work — a brisk 5-minute "
    "walk, daylight or a glass of water, then start with a small, easy win to "
    "build momentum.\n"
    "— Recovering / rest: protect the recovery — step back from demanding work "
    "for now, do light admin or take a real break, so you come back sharper for "
    "the important work.\n"
    "Give a specific, doable action and keep it encouraging.\n"
    "Keep the whole reply under 60 words. Only rely on the metrics provided.\n"
    "\n"
    "Match your TONE to the state:\n"
    "— Struggling states (overloaded_exhausted, stressed_activated, "
    "depleted_numb, shutdown_burnout): be warm, empathetic and reassuring; "
    "suggest gentle, low-effort steps and never pressure them.\n"
    "— Strong states (engaged_performing, calm_alert, renewed_thriving): be "
    "encouraging and motivating; nudge them to make the most of this window.\n"
    "— Steady states (stable_neutral, recovering_resetting): be calm and "
    "grounding; reinforce small, consistent habits.\n"
    "\n"
    "Pay special attention to Inner noise (PIP) and DFA alpha-1 as a proxy for "
    "mental focus: low, falling inner noise together with DFA alpha-1 near 1.0 "
    "signals sharp, absorbed focus (a good time for deep work); rising inner "
    "noise or DFA alpha-1 drifting toward 0.5 signals scattered, restless "
    "attention (suggest a reset — a few slow breaths or a short movement break). "
    "When these two are present, make one bullet about focus and let it steer "
    "the recommendation.\n"
    "\n"
    "Classify the person into EXACTLY ONE of the 9 nervous-system states below. "
    "Decide the state STRICTLY from the LAST 10 MINUTES of data across ALL NINE "
    "metrics — the current value ('now'), the window average ('window_avg'), the "
    "range and the trend. Do NOT use 'day_avg' to choose the state; the daily "
    "average is background context you may cite in a bullet (e.g. 'below your "
    "day's average') but it never decides the state. Weigh all nine metrics "
    "together, not just one.\n"
    "First read two axes:\n"
    "— STRESS / OVERLOAD is higher when Inner Noise (PIP), LF/HF and HR are high.\n"
    "— RECOVERY / REGULATION is higher when HRV (RMSSD/SDNN), RSA, Vagal Tone "
    "(DC) and ln RMSSD are high.\n"
    "Energy / activation is higher when HRV, HR and Adaptive Capacity (RCMSE) are "
    "higher. IMPORTANT: a high or rising HR with GOOD recovery metrics (solid "
    "RSA/RMSSD/DC, balanced LF/HF) is high ENERGY, not stress — do not call "
    "it a stress state.\n"
    "\n"
    "The 9 states — the key on the left is what you put first on line 1:\n"
    "1. overloaded_exhausted — Overloaded & Exhausted — high stress, low energy, "
    "low recovery; drained, overwhelmed, unable to cope. Signature: Inner Noise "
    "↑↑, HRV/DC ↓↓. Focus: rest, downshift, restore safety.\n"
    "2. stressed_activated — Stressed & Activated — high stress, high energy, low "
    "recovery; tense, wired, pushed. Signature: LF/HF ↑↑, Inner Noise ↑. Focus: "
    "regulate stress, balance effort.\n"
    "3. engaged_performing — Engaged & Performing — moderate stress, high energy, "
    "good recovery; focused, motivated, in control. Signature: DFA alpha-1 ~1.0, "
    "VTI optimal. Focus: sustain, flow, stay balanced.\n"
    "4. depleted_numb — Depleted & Numb — low energy, moderate stress, low "
    "recovery; flat, unmotivated, disconnected. Signature: HR ↓, VTI ↓. Focus: "
    "gentle activation, rebuild energy.\n"
    "5. stable_neutral — Stable & Neutral — balanced stress, energy and recovery; "
    "calm, steady, functional. Signature: all metrics near baseline. Focus: "
    "maintain, small positive habits.\n"
    "6. calm_alert — Calm & Alert — low stress, high energy, high recovery; "
    "clear, calm, capable. Signature: RSA ↑, DC ↑. Focus: grow, learn, create.\n"
    "7. shutdown_burnout — Shutdown & Burnout — very low energy, high stress, "
    "very low recovery; stuck, drained. Signature: HRV/DC ↓↓↓, Inner Noise ↑↑↑. "
    "Focus: deep rest; suggest seeking help if this persists.\n"
    "8. recovering_resetting — Recovering & Resetting — low energy, low stress, "
    "improving recovery; recharging, resetting. Signature: HR ↓, HRV/DC ↑. "
    "Focus: rest, nourish, be patient.\n"
    "9. renewed_thriving — Renewed & Thriving — low stress, high energy, very "
    "high recovery; alive, present, resilient. Signature: RSA ↑↑, RMSSD ↑↑. "
    "Focus: "
    "purpose, connection, contribute.\n"
    "\n"
    "Line 1 is '<state_key> | <fresh title>'. The bullets interpret the strongest "
    "trends (include focus when Inner Noise / DFA alpha-1 are telling). The '→' "
    "line turns that state's Focus into one concrete action for right now, in the "
    "tone that matches the state."
)


def get_openai_client() -> AsyncOpenAI:
    """FastAPI dependency — overridden with a fake in tests."""
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    return AsyncOpenAI(api_key=api_key)


# The metrics one session is read from, in the order the session detail shows
# them, under the names it shows them by. This mirrors the app's
# `activityMetricDefs` (ios/Wythin/UI/Activities/ActivityMetricsGrid.swift):
# the read is printed directly beneath those charts, so a read naming a measure
# the screen does not carry — or naming a charted measure something else — is
# describing a session the person cannot see.
#
# The raw LF/HF ratio is deliberately absent even when a client sends it. It
# rises during slow paced breathing because the vagal peak moves out of the HF
# band into LF, so handing it to the model has it read the most calming thing
# a person can do as sympathetic activation — which is exactly what it did,
# on a breath-hold session, before this list existed. Stress Balance is the
# breathing-robust dial the app uses instead, and it is here.
_ACTIVITY_METRICS = [
    ("dc",     "Vagal Tone",          "ms",  "relaxation and recovery capacity — how readily the heart slows; higher = a stronger brake"),
    ("rcmse",  "Adaptive Capacity",   "",    "how flexible the system is across timescales; higher = more resilient and responsive"),
    ("pip",    "Inner Noise",         "%",   "beat-to-beat jitter — erratic, non-restorative variability; lower = a cleaner, calmer signal"),
    ("dfa1",   "Harmony",             "",    "the fractal balance of the heartbeat, with ~1.0 the healthy sweet spot"),
    ("stress", "Stress Balance",      "",    "a breathing-robust 0–100 dial of how revved-up versus calm; lower = shifting into rest-and-digest, and slow paced breathing correctly reads as calmer here"),
    ("breath", "Breath Rate",         "br/min", "how fast the person was breathing; lower means slower, and slow breathing is the one thing here they steer on purpose"),
    ("rsa",    "Conscious Breathing", "ms",  "how far heart rate swings with each breath; higher = slow, deep, deliberate breathing is landing"),
    ("rmssd",  "Calm Power",          "ms",  "core beat-to-beat variability, the headline marker of recovery; higher = a rested, adaptable system"),
    ("hr",     "Pulse",               "bpm", "the overall load on the heart; lower during a calming practice means stress is being offloaded"),
    ("sdnn",   "Overall Variability", "ms",  "the total spread of beat-to-beat intervals, every rhythm folded into one number"),
]


def _format_metrics(req: InsightRequest) -> str:
    lines = [f"Activity: {req.activity_type}"]
    if req.activity_subtype:
        lines.append(f"Subtype: {req.activity_subtype}")
    if req.duration_min is not None:
        lines.append(f"Duration: {req.duration_min} min")

    for key, name, unit, meaning in _ACTIVITY_METRICS:
        before = getattr(req, f"before_{key}", None)
        during = getattr(req, f"during_{key}", None)
        after  = getattr(req, f"after_{key}", None)
        if before is None and during is None and after is None:
            continue
        lines.append(
            f"{name} ({meaning}): "
            f"before={before}{unit} during={during}{unit} after={after}{unit}"
        )
    return "\n".join(lines)


# Human-readable names so the model interprets each metric correctly instead of
# guessing from the abbreviation (e.g. it must not read PIP as "peripheral").
_METRIC_NAMES = {
    "hr":         "Heart rate (bpm)",
    "rmssd":      "RMSSD — short-term HRV / vagal tone (ms)",
    "rsa":        "RSA — breathing-driven heart-rate swing / vagal tone (ms)",
    "sdnn":       "SDNN — overall HRV (ms)",
    "lf_hf":      "LF/HF — stress-vs-rest balance (higher = more stress)",
    "coherence":  "Coherence — heart–breath synchronization (0–1)",
    "breath_bpm": "Breathing rate (breaths/min)",
    "cbi":        "Cardiac balance index",
    "dc":         "Vagal Tone (deceleration capacity, ms) — relaxation & recovery "
                  "capacity; higher = stronger parasympathetic brake",
    "rcmse":      "Adaptive Capacity (multiscale entropy) — flexibility/resilience "
                  "across timescales; higher = more adaptable",
    # ln of the quantity `rmssd` already carries. It must NOT be glossed
    # "Calm Power": that is the app's name for raw RMSSD, on the card the
    # live read is printed beside, and two meanings for one name is exactly
    # the drift this whole table exists to prevent.
    "vti":        "ln RMSSD — the log of RMSSD above; the same restorative "
                  "parasympathetic drive on a compressed scale",
    "pip":        "Inner noise — beat-to-beat fragmentation; a focus proxy "
                  "(lower = smoother, more settled attention; higher = scattered/restless)",
    "dfa1":       "DFA alpha-1 — fractal organization of the rhythm; a focus proxy "
                  "(near 1.0 = well-ordered, absorbed/focused; drifting toward 0.5 = "
                  "random/uncoupled; above ~1.2 = overly rigid)",
    "stress_balance": "Stress balance — breathing-robust 0–100 arousal dial "
                      "(lower = calmer). Not a raw frequency-domain stress "
                      "ratio; slow paced breathing correctly reads as calmer, "
                      "not more stressed",
}


def _format_live_state(req: InsightRequest) -> str:
    lines = [
        f"Window: last {req.window_minutes} minutes, split into five equal "
        f"buckets (oldest first). 'now' is the latest value, 'slope' is the "
        f"change across the whole window, and 'shape' names the arc. No "
        f"averages or norms are provided \u2014 describe only this window."
    ]
    for name, trend in (req.metrics or {}).items():
        label = _METRIC_NAMES.get(name, name)
        lines.append(f"{label}:")
        if trend.buckets:
            arc = " \u2192 ".join(f"{v:.1f}" for v in trend.buckets)
            lines.append(f"  buckets: {arc}")
        lines.append(
            f"  now={trend.now} | slope={trend.slope_pct}% | "
            f"volatility={trend.volatility} | shape={trend.shape} | "
            f"range={trend.min}-{trend.max}"
        )
    return "\n".join(lines)


_DAY_POTENTIAL_SYSTEM_PROMPT = (
    "You are an expert physiologist writing the 'today's potential' read-out "
    "for a person wearing a chest strap. You are given a capacity score the "
    "app already computed from their FIRST RESTED READING of the day compared "
    "with their own personal baseline \u2014 you never compute, state, or "
    "contradict the number. Reply in EXACTLY this plain-text structure, "
    "nothing before or after:\n"
    "\n"
    "<fresh 2-3 word title>\n"
    "\u2022 <how today's rested reading compares with their own usual range>\n"
    "\u2022 <what the pattern across recent mornings shows>\n"
    "\u2192 <what today can realistically hold>\n"
    "\n"
    "Example reply:\n"
    "Good Reserves\n"
    "\u2022 Your first still reading came in **at the top of your usual range** "
    "\u2014 the strongest start you've had in a week.\n"
    "\u2022 Your mornings are **settling back into a steady rhythm** after "
    "midweek's dip.\n"
    "\u2192 Room for one genuinely hard block and a full session \u2014 don't "
    "spend it all before noon.\n"
    "\n"
    "EXACTLY 2 bullets. Wrap the single KEY IDEA of each bullet in **double "
    "asterisks**. Speak in plain everyday language about capacity, reserves, "
    "and what the body can carry today. NEVER use technical terms \u2014 no "
    "HRV, RMSSD, RSA, SDNN, DFA, LF/HF, 'vagal tone', 'coherence', 'entropy', "
    "'deceleration'. ('Inner noise' is fine \u2014 it is one of the app's own "
    "labels.) Never mention z-scores, weights, or the word 'baseline'; say "
    "'your usual range' instead.\n"
    "\n"
    "If the fragmentation modifier is above zero, do NOT describe recovery or "
    "reserves as high however good the rest looks \u2014 the rhythm is erratic, "
    "and that inflates the underlying measure rather than reflecting real "
    "recovery.\n"
    "If provisional is true the score is real but early — it is built on "
    "only a few mornings, so it leans on typical ranges rather than fully on "
    "theirs. Say what the number shows, note that their own range is still "
    "forming and the read will sharpen, and do not draw firm conclusions from "
    "a single morning. Never imply the number is meaningless or unavailable.\n"
    "If there is no score at all there is not yet enough history for a "
    "personal range: compare only with the immediately preceding mornings, "
    "claim no norms, and say the app is still learning what is normal for "
    "them.\n"
    "If confidence is 'low', or late is true, hedge accordingly.\n"
    "The title must vary \u2014 never simply echo the band name. Keep the whole "
    "reply under 60 words."
)


def _format_day_potential(req: InsightRequest) -> str:
    lines = []
    if req.score is not None:
        note = " \u2014 provisional, the range is still forming" if req.provisional else ""
        lines.append(f"Capacity score: {req.score}/100 (band: {req.band}){note}")
    else:
        lines.append("Capacity score: not yet available \u2014 no earlier morning to compare with.")
    lines.append(
        f"Rested reading: {req.anchor_hour:.1f}h, {req.anchor_duration_min} min, "
        f"late={req.late}, confidence={req.confidence}"
    )
    lines.append(
        f"History: {req.baseline_anchors} of {req.baseline_target} readings, "
        f"sufficient={req.baseline_sufficient}, provisional={bool(req.provisional)}"
    )
    for name, comp in (req.components or {}).items():
        lines.append(f"{name}: z={comp.z} ({comp.level})")
    for name, value in (req.modifiers or {}).items():
        lines.append(f"modifier {name}: -{value}")
    if req.recent:
        lines.append(
            "Recent morning scores (oldest first): "
            + ", ".join(str(v) for v in req.recent)
        )
    if req.streak_current is not None:
        lines.append(
            f"Streak: {req.streak_current} mornings (best {req.streak_best}, "
            f"grace_used={req.grace_used})"
        )
    return "\n".join(lines)


_MACRO_TREND_SYSTEM_PROMPT = (
    "You are an expert physiologist writing the 'macro read' at the top of a "
    "long-term trends screen for a person wearing a chest strap. You are given "
    "each metric's average over the period, a baseline for comparison, a "
    "benefit-signed change versus the previous period, and how many buckets "
    "beat the baseline. The baseline is EITHER the person's own 90-day history "
    "OR, when they don't yet have enough of their own data, a generic typical "
    "range — the input tells you which, per metric. Only speak of 'their own "
    "baseline' or their personal history when the input marks that metric's "
    "baseline as personal; when it is generic, call it a typical or usual "
    "range instead and do NOT claim it reflects their history. Every number "
    "was computed by the app: never compute, restate more precisely, or "
    "contradict one, and never invent a metric you were not given.\n\n"
    "Reply in EXACTLY this plain-text structure — nothing else, no headings, "
    "no greeting, no markdown beyond the bold spans:\n"
    "• <the first specific thing the period shows>\n"
    "• <a second, if there is a genuinely separate one>\n"
    "• <a third, if there is one>\n"
    "→ <one concrete action for the coming period>\n"
    "→ <optionally a second action>\n\n"
    "BULLETS — at most THREE, one line each, ONE specific idea per bullet, no "
    "padding or throat-clearing. Name the metric by its plain-English name and "
    "say what the PATTERN over the period is, not what each number was. Wrap "
    "the single key idea of each bullet in **double asterisks** to bold it — "
    "the takeaway, exactly one short bold span per bullet — the same "
    "convention the live-state read already uses for its own bullets.\n"
    "ACTIONS — one or two '→' lines, concrete and specific to the coming "
    "period, matched to what the bullets found.\n"
    "delta_pct is benefit-signed: positive always means improvement, including "
    "where the raw value fell. A positive delta on Inner noise or Stress "
    "balance means it went DOWN, which is good — never describe it as a rise.\n"
    "No bullet characters other than '•' and '→', no other markdown, no "
    "greeting. Plain, warm, direct. Keep the whole reply under 70 words. Do "
    "not use the words 'HRV', 'RMSSD', 'LF/HF', 'entropy' or 'PIP' — use the "
    "plain-English names given."
)


_PERIOD_LABELS = {
    "week":      "this week",
    "month":     "this month",
    "six_month": "these six months",
}


# Macro-trend-only names, overlaid on `_METRIC_NAMES` for the seven keys the
# Track screen sends. `_METRIC_NAMES` itself is deliberately untouched: it is
# shared with `live_state` and `activity`, where the clinical glosses are
# correct and wanted.
#
# The source of truth here is the app's own card headings and "why" copy —
# `activityMetricDefs` in ios/Wythin/UI/Activities/ActivityMetricsGrid.swift —
# because the macro read sits directly above those very cards. A read that
# names a metric differently from the card two inches below it is worse than
# no read at all.
#
# Two hard constraints, both guarded by
# `test_macro_trend_names_avoid_every_banned_token`:
#
#  1. None of the tokens `_MACRO_TREND_SYSTEM_PROMPT` forbids in the OUTPUT
#     ("HRV", "RMSSD", "LF/HF", "entropy", "PIP") may appear in the INPUT.
#     Handing the model a banned word as a metric's only available name forces
#     it either to break the ban or to invent a name of its own.
#  2. "Vagal Tone" is the app's name for `dc` and for nothing else. No other
#     metric may be glossed with that phrase, or the read would say "your
#     vagal tone rose" while the VAGAL TONE card on the same screen shows a
#     fall — the reader has no way to tell which one is wrong.
_MACRO_TREND_METRIC_NAMES = {
    "dc": "Vagal Tone — relaxation and recovery capacity; how readily the "
          "heart slows. Higher = a stronger brake, deeper recovery",
    "rmssd": "Calm Power — core beat-to-beat variability, the headline "
             "marker of recovery. Higher = a rested, adaptable system",
    "rsa": "Conscious Breathing — how far heart rate swings with each breath. "
           "Higher = slow, deep, deliberate breathing is landing",
    "rcmse": "Adaptive Capacity — how flexible the system is across "
             "timescales. Higher = more resilient and responsive",
    "dfa1": "Harmony — the fractal balance of the heartbeat, with ~1.0 the "
            "healthy sweet spot. Closer to 1.0 = better-organised regulation; "
            "drifting low = uncoupled, running high = rigid",
    "pip": "Inner Noise — beat-to-beat jitter; erratic, non-restorative "
           "variability and a focus proxy. Lower = a cleaner, calmer signal",
    "stress_balance": "Stress Balance — a breathing-robust 0–100 dial of how "
                      "revved-up versus calm the person is. Lower = shifting "
                      "into rest-and-digest; slow paced breathing correctly "
                      "reads as calmer, not more stressed",
}


# --- sleep ------------------------------------------------------------------

# The night is read under the names the night screen uses, for the same reason
# the macro read is: this text is printed on the same screen as the charts,
# directly under `SleepMetricChart`, which titles every line from
# `activityMetricDefs`. A read naming a measure the screen does not carry is
# describing a night the person cannot see.
#
# Same two hard constraints as `_MACRO_TREND_METRIC_NAMES`, guarded by
# `test_sleep_prompt_names_avoid_every_banned_token`: no token the prompt bans
# in the output may appear in the input, and "Vagal Tone" names `dc` alone.
_SLEEP_METRIC_NAMES = {
    "dc": "Vagal Tone — how readily the heart slows; the recovery brake. "
          "Rising through a night is what restorative sleep looks like",
    "rmssd": "Calm Power — core beat-to-beat variability, the headline marker "
             "of recovery. Higher = a rested, adaptable system",
    "rsa": "Conscious Breathing — how far heart rate swings with each breath. "
           "Higher = slow, deep breathing",
    "rcmse": "Adaptive Capacity — flexibility across timescales. Higher = more "
             "resilient",
    "dfa1": "Harmony — the fractal balance of the heartbeat, ~1.0 the sweet spot",
    "pip": "Inner Noise — beat-to-beat jitter; erratic, non-restorative "
           "variability. Lower is better",
    "stress_balance": "Stress Balance — a breathing-robust 0-100 arousal dial. "
                      "Lower = further into rest-and-digest",
    "hr": "Pulse — the load on the heart. It should fall into the night and "
          "bottom out somewhere in the middle of it",
    "sdnn": "Overall Variability — the total spread of beat-to-beat intervals",
    "breath_bpm": "Breath Rate — breaths per minute",
}

_SLEEP_SYSTEM_PROMPT = (
    "You are a sleep physiologist reading ONE measured night from a chest "
    "strap, written for the person who slept it. Every number was computed "
    "on-device and is given to you: never compute a new one, restate one more "
    "precisely than it is given, contradict one, or mention a measure you were "
    "not handed.\n"
    "\n"
    "WHAT THE NUMBERS ARE AND ARE NOT:\n"
    "— Stage minutes are a SHAPE, not a clinical hypnogram. They come from a "
    "cardiac signal cut at typical adult shares, so read the pattern (was deep "
    "sleep early, did REM get its late blocks) and never treat a stage total as "
    "exact or compare it to a textbook target to the minute.\n"
    "— Awake time is the least reliable channel any wearable has. Treat wake "
    "minutes and wake-bout counts as approximate.\n"
    "— You are NOT diagnosing. Never name or imply a condition — no apnea, no "
    "insomnia, no restless legs, no disorder of any kind, and no diagnosis or "
    "diagnostic language even hedged. Breathing steadiness is not an event "
    "rate. If the night looks unusual, say what the numbers show and suggest "
    "the person raise it with a clinician; do not name the thing.\n"
    "— Body position: when the input says position was NOT recorded, that means "
    "the sensor never stored it on this night. It does NOT mean the person "
    "never lay on their back. Say nothing about position at all in that case.\n"
    "— Left versus right side depends on which way round the strap was "
    "fastened, so never build a recommendation on which SIDE they lay on; "
    "supine (on the back) is reliable and is the one worth acting on.\n"
    "\n"
    "NAMES: call every measure by the exact name given in the input — Vagal "
    "Tone, Calm Power, Conscious Breathing, Adaptive Capacity, Inner Noise, "
    "Harmony, Stress Balance, Pulse, Overall Variability, Breath Rate. NEVER "
    "use the underlying abbreviation or family: no HRV, RMSSD, SDNN, LF/HF, "
    "PIP, DFA, RSA or entropy.\n"
    "\n"
    "Reply in EXACTLY this plain-text structure — nothing before or after, no "
    "headings, no greeting, no markdown beyond the bold spans:\n"
    "<3-6 word headline naming what kind of night this was>\n"
    "\u2022 <the most important thing the night shows>\n"
    "\u2022 <a second, genuinely separate one>\n"
    "\u2022 <a third, if there is one>\n"
    "\u2192 <one concrete thing to change tonight>\n"
    "\u2192 <a second, for the week>\n"
    "\n"
    "BULLETS — at most THREE, one line each, one specific idea per bullet, "
    "plain everyday language. Ground each in the ARC of the night — what moved, "
    "WHEN it moved, and whether it held — not in a night average, and connect "
    "it to how the person would have felt. Wrap the single key takeaway of each "
    "bullet in **double asterisks**, exactly one short bold span per bullet.\n"
    "ACTIONS — one or two '\u2192' lines. Each must be specific, doable "
    "tonight or this week, and follow from a bullet: a fixed wake time, an "
    "earlier last meal or last drink, a darker or cooler room, winding down "
    "earlier, cutting caffeine past a certain hour, going to bed only when "
    "sleepy, getting light within an hour of waking, or sleeping off the back "
    "when supine dominated the night. Choose from what the numbers actually "
    "show; never give generic advice the data does not support.\n"
    "\n"
    "Keep the whole reply under 85 words. Speak directly to the person ('you'), "
    "warm and direct, no throat-clearing."
)


def _hm(minutes: int) -> str:
    return f"{minutes // 60}h {minutes % 60:02d}m"


def _pct(part: int, whole: int) -> int:
    """Half away from zero, not Python's half-to-even.

    The model quotes these shares back into text printed beside the app's own
    legend, which rounds with `Int(round(_))` — half away from zero. Banker's
    rounding would put 62% in the prose next to a 63% on the very same screen.
    """
    return int(math.floor(part / whole * 100 + 0.5))


def _format_sleep(req: InsightRequest) -> str:
    n = req.sleep
    assert n is not None      # guarded by the endpoint

    lines: list[str] = []

    when = []
    if n.bedtime:   when.append(f"asleep window opened {n.bedtime}")
    if n.wake_time: when.append(f"closed {n.wake_time}")
    if when:
        lines.append("Night: " + ", ".join(when))

    # The pair, never the single number — the gap between them IS the wake
    # time, which is the disclosure the whole screen exists to make.
    if n.asleep_min is not None:
        span = f"{_hm(n.asleep_min)} asleep"
        if n.in_bed_min:
            eff = _pct(n.asleep_min, n.in_bed_min)
            span += f" of {_hm(n.in_bed_min)} in bed ({eff}% of the time in bed)"
        lines.append(span)

    if n.score is not None:
        lines.append(f"Sleep score {n.score}/100 (the app's own, already shown)")
    if n.section_scores:
        lines.append("Sections (0-100, the app's own): " + ", ".join(
            f"{k} {v}" for k, v in n.section_scores.items()))

    if n.stages:
        st = [("Deep (N3)", n.stages.n3), ("Light (N2)", n.stages.n2),
              ("REM", n.stages.rem), ("N1", n.stages.n1), ("Awake", n.stages.wake)]
        parts = []
        for label, mins in st:
            if mins is None:
                continue
            share = (f" ({_pct(mins, n.asleep_min)}% of sleep)"
                     if n.asleep_min and label != "Awake" else "")
            parts.append(f"{label} {mins}m{share}")
        if parts:
            lines.append("Stage shape (approximate, cut at typical adult "
                         "shares): " + ", ".join(parts))

    cont = []
    if n.wake_bouts is not None:
        cont.append(f"{n.wake_bouts} wake bouts")
    if n.longest_wake_min is not None:
        cont.append(f"longest {n.longest_wake_min}m")
    if cont:
        lines.append("Continuity: " + ", ".join(cont) + " (approximate)")

    if n.regularity is not None:
        lines.append(f"Sleep Regularity {n.regularity:.0f}/100 — how alike this "
                     f"night's timing is to the recent nights before it")

    if n.lowest_hr is not None:
        at = f" at {n.lowest_hr_at}" if n.lowest_hr_at else ""
        lines.append(f"Lowest Pulse {n.lowest_hr:.0f} bpm{at}")
    if n.breath_bpm is not None:
        lines.append(f"Breath Rate {n.breath_bpm:.1f} breaths/min across the night")

    # Position, stated either way. An omission would read as "never on their
    # back", which is a claim the sensor did not make.
    if not n.position_recorded or not n.positions:
        lines.append("Body position: NOT RECORDED on this night — the strap "
                     "stored no orientation, so nothing whatever is known about "
                     "how they lay. Do not mention position.")
    else:
        shares = []
        for p in n.positions:
            share = (f" ({_pct(p.minutes, n.asleep_min)}% of sleep)"
                     if n.asleep_min else "")
            shares.append(f"{p.position} {p.minutes}m{share}")
        lines.append("Body position: " + ", ".join(shares) +
                     " — supine means on the back; left/right is unreliable "
                     "because it depends on strap orientation")

    if n.arcs:
        lines.append("Through the night — each measure's first half against its "
                     "second half, which is where the recovery story is:")
        for key, arc in n.arcs.items():
            label = _SLEEP_METRIC_NAMES.get(key, key)
            bits = []
            if arc.first_half is not None:
                bits.append(f"first half {arc.first_half:.1f}")
            if arc.second_half is not None:
                bits.append(f"second half {arc.second_half:.1f}")
            if arc.night_avg is not None:
                bits.append(f"night average {arc.night_avg:.1f}")
            if bits:
                # Name and gloss on their own line, values indented under it —
                # the same two-line shape `_format_macro_trend` uses, because a
                # sentence-long gloss followed by a colon and four numbers is
                # one long run-on the model has to unpick.
                lines.append(f"  {label}")
                lines.append("    " + " | ".join(bits))

    return "\n".join(lines)



def _format_macro_trend(req: InsightRequest) -> str:
    span = _PERIOD_LABELS.get(req.period or "", "this period")
    unit = "months" if req.period == "six_month" else "days"
    lines = [
        f"Period: {span} ({req.range_label}). Averages are over the "
        f"{unit} in the period; 'vs prior' compares with the previous "
        f"period of the same length."
    ]
    for key, t in (req.trends or {}).items():
        # Track's own names first; `_METRIC_NAMES` only as a fallback for a
        # key this mode does not (yet) have a screen-matched name for.
        label = _MACRO_TREND_METRIC_NAMES.get(key) or _METRIC_NAMES.get(key, key)
        # A missing flag (older client) is treated as generic, not personal —
        # the safe default is to under-claim personalization, never over-claim it.
        personal = bool(t.baseline_is_personal)
        parts = [f"avg={t.avg:.2f}"]
        if t.baseline is not None:
            if personal:
                parts.append(f"baseline={t.baseline:.2f} (the person's own 90-day baseline)")
            else:
                parts.append(f"typical={t.baseline:.2f} (a generic reference range, not personal history)")
        if t.delta_pct is not None:
            parts.append(f"vs prior={t.delta_pct:+.0f}% (benefit-signed)")
        if t.days_above is not None and t.days_total is not None:
            ref = "their own baseline" if personal else "the typical range"
            parts.append(f"{t.days_above} of {t.days_total} {unit} better than {ref}")
        lines.append(f"{label}:")
        lines.append("  " + " | ".join(parts))
    return "\n".join(lines)


async def require_ai_consent(
    x_user_id: str | None = Header(None, alias="X-User-ID"),
) -> str:
    """Refuse the request unless this device has opted in to AI guidance.

    This endpoint is the only place user metrics leave our infrastructure for a
    third-party model, so it is the only place the consent has to hold.

    A missing header is refused rather than waved through: a client that doesn't
    identify itself can't have its consent checked, and "couldn't check" has to
    resolve to no. That does mean an app build predating the header gets a 403
    and shows no insight — the correct failure for a consent control, and why
    this is a deliberate breaking change rather than an oversight.

    It's a dependency, not an inline check, so it can be overridden in tests the
    same way the OpenAI client is.
    """
    if not x_user_id or not await has_ai_insights_consent(x_user_id):
        raise HTTPException(
            status_code=403,
            detail="AI insights require consent; enable it in Settings.",
        )
    return x_user_id


@router.post("/insights", response_model=InsightResponse)
async def generate_insight(
    req: InsightRequest,
    _user_id: str = Depends(require_ai_consent),
    client: AsyncOpenAI = Depends(get_openai_client),
):
    if req.mode == "day_potential":
        if req.anchor_hour is None or req.baseline_sufficient is None:
            raise HTTPException(status_code=422, detail="anchor and baseline are required for day_potential mode")
        if req.baseline_sufficient and req.score is None:
            raise HTTPException(status_code=422, detail="score is required when the baseline is sufficient")
        # A provisional baseline still produces a number. The scoreless case is
        # now only the very first morning, which legitimately has no `recent`
        # either — so there is nothing further to require.
        if req.provisional and req.score is None:
            raise HTTPException(status_code=422, detail="score is required when the baseline is provisional")
        system_prompt = _DAY_POTENTIAL_SYSTEM_PROMPT
        user_content = _format_day_potential(req)
        max_tokens = 200
    elif req.mode == "live_state":
        if not req.metrics:
            raise HTTPException(status_code=422, detail="metrics is required for live_state mode")
        system_prompt = _LIVE_STATE_SYSTEM_PROMPT
        user_content = _format_live_state(req)
        max_tokens = 260   # arc phrasing needs a little more room
    elif req.mode == "sleep":
        # A night with no measured sleep is not a night to interpret. Refusing
        # here beats handing the model an empty window and letting it narrate
        # one anyway.
        if req.sleep is None or not req.sleep.asleep_min:
            raise HTTPException(status_code=422,
                                detail="sleep.asleep_min is required for sleep mode")
        system_prompt = _SLEEP_SYSTEM_PROMPT
        user_content = _format_sleep(req)
        # The night read is the longest of the four: a headline, up to three
        # bullets with bold spans, and two actions. Its own cap ("under 85
        # words") is the real limit; this only has to not cut it off first.
        max_tokens = 300
    elif req.mode == "macro_trend":
        if not req.trends:
            raise HTTPException(status_code=422, detail="trends is required for macro_trend mode")
        system_prompt = _MACRO_TREND_SYSTEM_PROMPT
        user_content = _format_macro_trend(req)
        # 180 sized the old two-sentences-plus-actions shape. The bulleted
        # shape's own cap ("under 70 words") is tighter than that prose ever
        # was, but bullets add per-line overhead ('• ', '→ ', a bold span) a
        # raw word count doesn't capture — 150 leaves headroom for that
        # without giving the model back the room the word cap just removed.
        max_tokens = 150
    else:
        if not req.activity_type:
            raise HTTPException(status_code=422, detail="activity_type is required for activity mode")
        system_prompt = _SYSTEM_PROMPT
        user_content = _format_metrics(req)
        max_tokens = 150

    try:
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            max_tokens=max_tokens,
            temperature=0.6,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
        )
    except OpenAIError as e:
        raise HTTPException(status_code=502, detail=str(e))

    text = response.choices[0].message.content
    if not text or not text.strip():
        raise HTTPException(status_code=502, detail="Empty response from OpenAI")
    return InsightResponse(text=text.strip())
