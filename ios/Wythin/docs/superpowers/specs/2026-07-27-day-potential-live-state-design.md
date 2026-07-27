# Day Potential + Richer Live State — Design Spec
Date: 2026-07-27

## Overview

Two changes to the Live tab's state widget, driven by one idea: **capacity and load are different things and must be measured differently.**

1. **Day Potential** — a new, slow-moving readiness read derived from the first *rested* window of the day (the "anchor"), scored against the user's own 60-day anchor baseline. It answers "what have you got today?" It is computed locally, frozen once set, and explained by a once-daily LLM narrative. It carries a consecutive-mornings streak that nudges toward daily use.

2. **Current State**, revised — the existing 10-minute live read gets a much richer picture of the window (2-minute buckets, slope, volatility, shape) and **stops comparing to averages entirely**. All "vs your norm" language moves up into Day Potential.

Today's `live_state` insight conflates the two: it grounds bullets in `day_mean`, which is a running average across whatever the user happened to be doing. That is load, not capacity, and it makes the live read drift with behavior.

Related prior specs: `2026-07-18-live-state-widget-design.md`, `2026-07-17-openai-activity-insights-design.md`.

---

## 1. Scientific basis

What the literature validates is narrow, and the design stays inside it where it can:

- **lnRMSSD against a rolling personal baseline** is the validated daily-monitoring approach (Plews et al. 2012/2013; Buchheit 2014). Single-day-vs-single-day comparison is noise; a rolling mean against a 30–60-day baseline mean ± SD, with a smallest-worthwhile-change band, is the interpretation rule.
- **Short readings are valid** — 60 s RMSSD correlates r > 0.9 with the 5-minute reference (Esco & Flatt 2014; Munoz 2015) — *provided posture, time of day, and condition are held constant*. Standardization matters more than duration.
- **Deceleration capacity (DC)** was designed via phase-rectified signal averaging to survive nonstationarity and artifact, and outperformed LVEF and SDNN for post-MI mortality prediction (Bauer et al., Lancet 2006). Developed on 24 h Holter as a prognostic marker, not validated for daily readiness — so it is a secondary term here, and requires a longer anchor.
- **HR fragmentation (PIP)** dissociates from vagal tone: fragmented rhythms *inflate* short-term HRV indices including RMSSD while indicating worse autonomic function (Costa, Davis & Goldberger 2017). This is why PIP enters as a **penalty and validity check on the RMSSD reading, never as a bonus** — it is what stops the app congratulating a user on erratic beats.
- **LF/HF is excluded from scoring.** It does not measure sympathovagal balance (Billman 2013). It remains a live display metric only.
- **SDNN is excluded from scoring.** Over 5 minutes it is dominated by slow and respiratory components.
- **DFA α1** carries a small penalty for deviation from the user's own median in either direction. Most recent work uses it as an exercise-intensity marker (Rogers et al. 2021), and it is sensitive to artifact correction, so its weight stays low.
- **RCMSE** is excluded from the daily score — it needs longer series than an anchor provides.
- **RSA/HF** is excluded from scoring due to respiratory confounding, but breathing rate at the anchor is used as a validity gate (an atypical rate invalidates the read).

**Honest limitation, to be recorded in code comments:** no published work validates *this specific composite* as a readiness score, and the commercial equivalents (Whoop, Oura, Garmin — all of which use sleep-derived HRV rather than waking reads) do not publish theirs. The weights below are reasoned extension. They live in one constants table, every component z is logged alongside the final score, and the first months are treated as calibration. **If the composite ever disagrees with plain lnRMSSD in a way that cannot be explained, plain lnRMSSD is the one to trust.**

### Future: overnight anchors

The Polar H10's onboard memory stores one session (~30 h) of RR intervals recorded standalone, retrievable over Polar's PS-FTP service via the official `polar-ble-sdk`. Overnight RR would remove posture, behavior, and time-of-day confounds and is the gold-standard input for this feature. Out of scope here; noted so the anchor abstraction stays source-agnostic.

---

## 2. Anchor capture

### 2.1 New tick field: `motion`

Stillness detection needs accelerometer magnitude, which nothing currently persists.

- `MetricsEngine.compute` gains `motion: Float?` — the SD of the ACC vector magnitude over the snapshot window, from the `accXYZ` buffer already captured in `DataSnapshot`.
- Added to `MetricsTick`, `MetricsHistoryPoint`, and `HRVSample`. All three are additive optionals; the SwiftData migration is lightweight.

### 2.2 `AnchorDetector` (new, pure)

Scans one day of quality-filtered `MetricsHistoryPoint`s for the first window satisfying **all** of:

| Gate | Threshold |
|---|---|
| Duration | ≥ 5 min continuous preferred; ≥ 3 min accepted (see below) |
| Motion | `motion` ≤ `stillnessSD` |
| Motion (fallback, when `motion` is nil) | rolling SD of `meanBPM` ≤ 3 bpm |
| Signal quality | `signalQuality` ≥ 0.9 |
| RR artifact | `rrInvalidRate` ≤ 0.05 |
| ECG | `ecgQualityTier` ≥ 1 |
| Breathing plausibility | `breathBPM` within 8–20 br/min |

All thresholds live in one `AnchorThresholds` constants enum. `stillnessSD` starts at **20 mg** (H10 PMD reports ACC in mg; seated-still reads sit in the low single digits, typing and walking are an order of magnitude above) and is calibrated against real captures during implementation — the calibration is an implementation step, not a follow-up.

At 3–5 min, **DC is dropped from the core** (insufficient beats for a stable PRSA estimate) and its 0.30 weight is redistributed proportionally to lnRMSSD and resting HR. PIP needs ~100 beats, which a 3-minute window at rest barely clears; below that it is treated as unavailable and its penalty cannot fire.

Search prefers a window starting before 12:00. If none exists by then, the first qualifying window later in the day is used and flagged `late = true` (lower confidence, and the narrative is told).

**Output** — medians (not means; robust to a stray tick) of `vti` (= lnRMSSD, already computed), `dc`, `meanBPM`, `pip`, `dfa1`, `breathBPM`, plus start hour, duration, `late`, and the quality flags that were used.

### 2.3 `DailyAnchor` (new `@Model`)

One row per calendar day, written once when the anchor is first detected and then **frozen**. The freeze is what makes the score stable for the remainder of the day — it must never be recomputed as more data arrives.

Fields: `date`, `startedAt`, `durationSec`, `hour`, `lnRMSSD`, `dc`, `restingHR`, `pip`, `dfa1`, `breathBPM`, `late`, `motionKnown`, `confidence`.

`confidence` is `.high` (≥5 min, motion known, not late), `.medium` (3–5 min, or `late`), or `.low` (motion inferred from the HR-stability proxy — i.e. all backfilled anchors). Confidence is reported to the narrative but does not alter the arithmetic.

### 2.4 Backfill

Every field the detector needs is already persisted in `HRVSample` (`vti`, `dc`, `pip`, `dfa1`, `meanBPM`, `signalQuality`, `rrInvalidRate`, `ecgQualityTier`). On first run after upgrade, stored history is replayed day by day through the same detector with `motion` unavailable (HR-stability proxy applies) and the resulting anchors are marked `motionKnown = false`, `confidence = .low`. Users with existing history therefore do not start from an empty baseline.

---

## 3. `AnchorBaseline` (new, pure)

Rolling statistics over stored `DailyAnchor`s:

- **Per-component mean and SD** across the last 60 days. Requires **≥ 7 anchors** before any SD exists; below that, no score is produced (see §7).
- **Circadian control** — prefers anchors within ±2 h of today's anchor hour. If fewer than 7 match, falls back to all anchors and reduces confidence.
- **`CV₇`** — coefficient of variation of the last 7 lnRMSSD anchors, compared against its own 60-day norm. This is the stability axis; rising day-to-day variability is an early warning independent of the level (Plews' adaptation quadrants).

---

## 4. `PotentialScore` (new, pure)

```
CORE — capacity z, each component vs its own 60-day anchor baseline
  0.50 × z(lnRMSSD)
  0.30 × z(DC)                    // redistributed if anchor < 5 min
  0.20 × z(−restingHR)            // negated: lower is better
  → capacity_z
  → raw = clamp(round(50 + 25 × capacity_z), 0, 100)   // ±2 SD saturates at 0 / 100

MODIFIERS — capped penalties, never bonuses. z_x = z of x vs its own 60-day norm.
  stability       clamp(10 × z(CV₇) / 2, 0, 10)         → up to −10
  fragmentation   clamp(10 × z(PIP)  / 2, 0, 10)        → up to −10
                  and suppresses any "high recovery" claim in the narrative
  organization    clamp( 5 × |z(DFA α1)| / 2, 0, 5)     → up to −5

  score = clamp(raw − penalties, 0, 100)

GUARDS — change interpretation, not arithmetic
  saturation      lnRMSSD > +1 SD AND restingHR < −1 SD AND RMSSD/RR above its
                  personal norm → cap score at 75 and flag; the narrative says
                  "deeply rested" rather than celebrating a peak
  validity        anchor < 3 min, motion gate failed, rrInvalidRate > 0.05,
                  breathBPM outside 8–20 br/min or > 2 SD from personal median,
                  or anchor hour > 4 h from the personal median anchor hour
                  → no score at all (treated as "no anchor", §9)
```

Correlated metrics are deliberately **not** flat-averaged — every input is a lens on the same vagal axis, so an equal-weight mean silently over-weights whichever axis has the most representatives.

Returns the score **plus every component z and every applied penalty**, so the number is always explainable and unit-testable.

**Bands** are derived locally from the score; the band — not the LLM — drives colour and label:

| Score | Band key | Label | Colour |
|---|---|---|---|
| 80–100 | `full` | full reserves | accent |
| 60–79 | `good` | good reserves | accent |
| 40–59 | `steady` | steady | breathe |
| 25–39 | `light` | running light | warn |
| 0–24 | `depleted` | depleted | warn |

## 5. `StreakCompute` (new, pure)

Consecutive days with a valid anchor, **allowing one skipped day per rolling 7 without breaking the run**. Strict streaks punish travel and illness — precisely the days the data is most informative — and a broken streak is a common quit trigger. A grace day renders as a hollow dot that does not break the chain.

Also returns `best` (longest run) and total anchors toward the 60-reading baseline bar.

---

## 6. Backend — `POST /insights`

### 6.1 New mode: `day_potential`

Request adds:

```python
class PotentialComponent(BaseModel):
    z: Optional[float] = None
    level: Optional[str] = None          # "top of usual" | "below usual" | ...

class InsightRequest(BaseModel):
    mode: str = "activity"               # "activity" | "live_state" | "day_potential"
    # ... existing fields ...
    score:       Optional[int] = None
    band:        Optional[str] = None
    anchor:      Optional[dict] = None   # hour, duration_min, late, confidence
    components:  Optional[dict[str, PotentialComponent]] = None
    modifiers:   Optional[dict[str, float]] = None
    baseline:    Optional[dict] = None   # anchors, target, window_days, sufficient
    recent:      Optional[list[float]] = None   # last 7 anchor scores
    streak:      Optional[dict] = None   # current, best, grace_used
```

Validation, stated unambiguously: `mode == "day_potential"` requires `anchor` and `baseline`. It additionally requires `score` **when `baseline.sufficient` is true**, and requires a non-empty `recent` **when `baseline.sufficient` is false** (the day-over-day case, §7). Any other combination is 422.

**Response format** — the LLM supplies language only; score, band, and colour are already fixed by the client:

```
<fresh 2-3 word title>
• <capacity vs personal norm>
• <stability / weekly pattern>
→ <what today can hold>
```

Prompt rules: plain language, no technical terms (same ban list as `live_state`, which already permits "inner noise"); exactly 2 bullets; one bold `**key idea**` span per bullet; never state or contradict the numeric score; when `fragmentation` fired, do not describe recovery as high; when `baseline.sufficient` is false, use day-over-day language only and claim no norms.

`max_tokens = 200`, `temperature = 0.6`, `gpt-4o-mini` — consistent with the existing modes.

### 6.2 Revised mode: `live_state`

```python
class MetricTrend(BaseModel):
    now:        Optional[float] = None
    buckets:    Optional[list[float]] = None    # 5 × 2-min means
    slope_pct:  Optional[float] = None
    volatility: Optional[str] = None            # "low" | "moderate" | "high"
    shape:      Optional[str] = None
    min:        Optional[float] = None
    max:        Optional[float] = None
    # day_mean: REMOVED
```

**`day_mean` is deleted from this payload.** The model cannot compare to an average because it no longer receives one — enforcement by construction, not by prompt instruction, which leaks.

Client-side, `MetricTrend.dayMean` is **retained** in `LiveStateTrendCompute` — the local "how the day has gone so far" template (§7) needs it. Only `MetricTrendPayload` drops the field, so nothing day-average-shaped crosses the network in `live_state` mode.

`_format_live_state` renders per metric:

```
Energy (heart rate):
  buckets: 74.1 → 72.8 → 70.2 → 68.9 → 68.4
  now: 68.4 | slope: -7.7% over 10 min | volatility: low | shape: steady-fall
```

Prompt changes: bullets must describe the **arc** of the window (what moved, when in the window, and whether it held), grounded in the shape and slope; the existing instruction to compare against `day_avg` is removed, and comparison to any average or norm is explicitly forbidden — that is Day Potential's job. Bullet count stays at 3.

`max_tokens` rises to 260 to accommodate arc phrasing.

### 6.3 `TrendShape` (new, pure, client-side)

Classifies 5 bucket means into `steady-rise`, `steady-fall`, `plateau`, `spike-and-recover`, `dip-and-recover`, or `oscillating`, from monotonicity within tolerance, extremum position, and direction-reversal count. Computed on-device and sent as a string so the model reads a label rather than inferring an arc from similar-looking floats.

---

## 7. Cadence

| What | When |
|---|---|
| Anchor detection | Continuously, until the day's anchor is found; then stops for the day |
| `PotentialScore` | Once, at anchor detection. Frozen for the day |
| Day-potential narrative (LLM) | **Once per day**, at anchor detection. Cached. Regenerated only on pull-to-refresh |
| "How the day has gone so far" | **Local template**, no LLM — day-mean vs anchor → "spent steadily" / "in spikes" / "still holding". Updates continuously, never rewords itself |
| Live state | Unchanged: 15/20 s poll, 5-minute floor, forced on pull-to-refresh |

Net cost: **one extra LLM call per day**, not a second recurring one.

---

## 8. UI

A collapsed strip above `CURRENT STATE` inside the existing widget card, expanding on tap.

**`DayPotentialInsight`** (new, pure) parses the day-potential reply — first line is the title, `•` lines are bullets, `→` is the "what today can hold" block. It mirrors `LiveStateInsight` but has **no state key**: colour and label come from the locally-computed band, so there is nothing for the model to contradict. `LiveStateInsight`'s own format is unchanged.

**`DayPotentialStore`** (`@Observable`, mirrors `LiveStateStore`) owns anchor, score, narrative, and streak; loads `DailyAnchor` from SwiftData; triggers detection and the once-daily generation.

**`DayPotentialStrip`** renders:

- *Collapsed*: `☼ Today's potential · good reserves`, a filled bar, the score, chevron; below it 7 day-dots and the streak line; below that the baseline progress bar (`41 of 60 readings — your range sharpens as this fills`).
- *Expanded*: adds the anchor meta line (`MORNING READ · 07:12 · 4 MIN STILL`), a 7-day sparkline with the ±1 SD band shaded behind it, the two bullets, the "what today can hold" block, then a divider and the local "how the day has gone so far" line.

Expansion state persists in `@AppStorage`.

**States:**

| State | Strip |
|---|---|
| Scored | Band colour, score, bar, dots, baseline bar |
| No anchor yet | `waiting for a still moment`, score `—`, dashed bar, meta `NEEDS 3 MIN STILL`; today's dot amber; CTA: *"Three quiet minutes with the strap on keeps it going."* |
| Baseline building (< 7 anchors) | `learning your range`, `n/7` bar, no score, day-over-day bullet only |
| Low + unstable | Warn colour, both level and widening-spread sentences, gentler "what today can hold" |
| Logged today | No CTA at all. A personal best is the only thing remarked on |

---

## 9. Error handling

- **No anchor** → strip shows the waiting state and **no LLM call is made**.
- **Baseline insufficient** → no score; prompt told `sufficient: false`; day-over-day language only.
- **Network failure** → previous narrative persists; **the score still renders**, because it is computed on-device. The number never depends on the network.
- **Validity gate failed** → treated as "no anchor" for the day rather than scoring a motion artifact as fatigue.
- Server errors keep the existing behaviour: `OpenAIError` → 502, empty completion → 502.

---

## 10. Testing

Unit tests on the pure types (no LLM wording assertions anywhere):

- **`AnchorDetector`** — synthetic days: clean 5-min window; motion-contaminated; too short; artifact-heavy; no qualifying window; afternoon-only (`late`); `motion` nil → HR-stability proxy.
- **`PotentialScore`** — component z arithmetic; DC redistribution at 3–5 min; each penalty at and beyond its cap; saturation guard; validity gate; explainability payload completeness.
- **`AnchorBaseline`** — fewer than 7 anchors; ±2 h hour matching; fallback path and confidence reduction; 60-day windowing.
- **`StreakCompute`** — grace day preserves run; two misses break it; rolling-7 boundary; `best`.
- **`TrendShape`** — each shape from synthetic buckets, including near-tolerance cases.
- **`DayPotentialInsight`** — title/bullets/recommendation parsing, including malformed replies and missing sections.
- **Server** (`test_insights.py`) — `day_potential` 422 without `score`; prompt formatting for both modes; `day_mean` absent from `live_state` rendering.

---

## 11. Out of scope

- Overnight anchors via H10 offline recording (§1) — phase two.
- Autonomic reactivity / load-response ("how the body handles the first hour") — a third construct needing its own event detection and validation.
- Per-metric user-tunable weights (cf. practice impact weights, deferred the same way).
- Multi-day trend views beyond the 7-day sparkline.
