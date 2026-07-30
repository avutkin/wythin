# Provisional Day Potential — Scoring Before the Baseline Fills

Date: 2026-07-27

## Overview

Day Potential currently shows nothing — no score, an empty bar, a `—` — until the
user has logged **seven** morning anchors. `AnchorBaseline.build` returns `nil`
below `minimumAnchors`, so `PotentialScore.evaluate` is never reached and the
widget sits in `.baselineBuilding` for a week.

That week is exactly when a user decides whether the app is worth opening. They
get a blank number and a progress bar reading "0 of 60 readings", which implies
sixty mornings of work before anything happens. The 60 is `windowDays`, the
lookback length — not the unlock threshold — but nothing in the UI says so.

This spec replaces the hard gate with **shrinkage**: a real score from the second
morning onward, z-scored against a baseline that blends the user's own history
with a fixed prior, weighted by how much history exists. Early scores are
deliberately conservative and widen as the baseline firms up. The number is
labelled as early until day 7, but it is a real number the whole time.

Supersedes the `minimumAnchors` gate in
`2026-07-27-day-potential-live-state-design.md` §3. Everything else in that spec
— anchor detection, weights, penalties, the saturation guard — is unchanged.

---

## 1. Why not just "average the days you have"

The obvious fix is to build the baseline from whatever days exist. That gets a
**mean**, but the score is not built from a mean — it is built from a z-score,
and a z needs an SD:

```swift
func z(_ value: Float) -> Float? {
    guard sd > 1e-6 else { return nil }
    return (value - mean) / sd
}
```

An SD estimated from two or three days carries roughly 50% relative error. Since
the score is `50 + 25·z`, a naive early z produces a number that swings 40+ points
on estimation noise alone — 88 on Tuesday, 31 on Wednesday, identical sleep. That
is worse than showing nothing, because it teaches the user during their first
week that the number is meaningless.

The fix is not to avoid scoring early. It is to score early with an honest
uncertainty term.

---

## 2. Scoring math

Two distinct problems, each with its own term.

### 2.1 The SD is unstable

A spuriously *small* sample SD is what produces a monster z. Blend it toward a
fixed prior, weighted by ν "virtual days" of prior evidence:

```
sd_blend = sqrt( (ν·prior² + (n−1)·sd_personal²) / (ν + n − 1) )
```

At n = 1 the `(n−1)` term zeroes and `sd_blend` is exactly the prior — the
formula degrades correctly with no special case.

**Worked example.** n = 3, personal SD spuriously 0.05, prior 0.20:

```
sd_blend = sqrt((4·0.04 + 2·0.0025) / 6) = sqrt(0.0275) = 0.166
```

The resulting z is **3.3× smaller** than the naive `/0.05` would give. That is
the protection this term exists for.

### 2.2 The mean is unstable

At n = 2 the standard error of the mean is 0.71·sd. Today can read as extreme
purely because the two reference days happened to sit low. Widen by the standard
prediction-interval factor:

```
sd_pred = sd_blend · sqrt(1 + 1/n)
z       = (today − mean) / sd_pred
```

### 2.3 Both fade on their own

Multiplier applied to a typical personal SD:

| n | multiplier |
|---|---|
| 1 | 1.41× |
| 2 | 1.22× |
| 4 | 1.12× |
| 7 | 1.07× |
| 20 | 1.03× |

`sd_pred → sd_personal` as n grows. There is **no discontinuity at day 7** — the
label changes, the number does not jump. The prior also keeps mild protection
well past day 7, which is a bonus rather than a cost.

### 2.4 Constants

New, next to the existing weights in `PotentialScore` so the whole tuning surface
sits in one place:

```swift
enum BaselinePrior {
    /// Typical within-person day-to-day spread. Reasoned defaults, calibratable.
    static let lnRMSSD:   Float = 0.20  // ln units (≈20% RMSSD CV)
    static let restingHR: Float = 3.0   // bpm
    static let dc:        Float = 1.2   // ms
    static let pip:       Float = 4.0   // %

    /// Virtual days of prior evidence. At n = ν the blend is 50/50.
    static let strength: Float = 4
}
```

**Honest limitation, to sit in the code comment:** these are literature-informed
day-to-day variability figures, not this user's. They are an assumption, stated
as one. They matter most at n = 1 and are nearly irrelevant by n = 20. If early
scores read as systematically too extreme or too flat across real users, `strength`
is the first dial to turn.

**Calibration attempt, 2026-07-28.** Checked against 30 days of local morning
history in `just-breathe.db`: rolling-7 SD of daily median lnRMSSD had a median
of 0.275 (range 0.187–1.087). That sample is **ungated** — the table carries no
motion, signal-quality, or ECG-tier columns, so none of the anchor conditions
could be applied, and the continuity requirement could not be enforced either.
It is therefore an upper bound on anchor-gated spread, and 0.20 sits plausibly
below it. `restingHR` could not be checked at all: the same morning rows average
78 bpm with an SD of 19.7, which is activity, not rest, and there is no way to
extract a resting subset from what is stored. Treat 3.0 bpm as unverified.

Recalibrate both once ~30 real anchors exist — that is the sample this actually
needs, and it does not exist yet.

---

## 3. `AnchorBaseline` changes

- `build` returns a baseline from **1 prior anchor** onward instead of 7.
- `minimumAnchors = 7` stays in the file but changes meaning: it is now purely
  the **label** threshold, not a compute gate. Rename to `firmAnchors` to stop it
  reading as a gate.
- New field `provisional: Bool` — `anchorCount < firmAnchors`.
- `BaselineStat` gains the prior-blended z. `z(_:)` keeps its current behaviour
  for callers that want the raw statistic; a new `z(_ value:prior:n:)` applies
  §2, where `n` is the number of anchors the stat was built from (`BaselineStat.n`,
  already present). The degenerate-SD guard stays — with a prior in play it should
  now be unreachable, but it is cheap.
- Prior-blended z applies to the four scored components only (`lnRMSSD`,
  `restingHR`, `dc`, `pip`). `cv7Stat` keeps its raw z — it cannot exist below
  n = 8 anyway, and §6 handles its ramp. `dfa1Median` is unaffected: it already
  uses the fixed `dfa1Step` rather than a per-person SD.
- `hourMatched` continues to require `firmAnchors` near-hour samples. Hour
  matching is a luxury; below 7 anchors the baseline uses everything it has.

## 4. State machine

`DayPotentialStore.State` becomes five cases. This also closes an existing bug:
`DayPotentialStore.swift:89` currently collapses any `result == nil` into
`.waitingForStillness`, so a perfectly good 15:00 anchor on an 07:00 baseline —
rejected by `PotentialScore.maxHourDeviation` — reports "waiting for a still
moment" while the row directly below it prints `LATER READ · 15:12 · 6 MIN STILL`.

| State | Condition | Headline |
|---|---|---|
| `.waitingForStillness` | no anchor today | `WAITING FOR A STILL MOMENT` |
| `.firstMorning` | anchor today, zero prior anchors | `MORNING READ · FIRST ONE LOGGED` |
| `.scored(provisional: true)` | 1–6 prior anchors | `TODAY'S POTENTIAL · {BAND} · EARLY DAYS` |
| `.scored(provisional: false)` | ≥ 7 prior anchors | `TODAY'S POTENTIAL · {BAND}` |
| `.notComparable` | anchor + baseline, `evaluate` → nil | `LATER READ · NOT COMPARABLE TODAY` |

`.firstMorning` has no score because there is no reference day at all. It is not
an error state and should not read as one.

## 5. UI

- **Progress bar** retargets to `firmAnchors` while provisional:
  `"3 of 7 readings — your range is still forming"`. Hidden once firm. The
  current `n of 60` is the most discouraging element in the widget and goes away.
- **Sparkline** already requires `recent.count >= 2` and now populates during the
  provisional phase, since past anchors can be scored against the same blended
  baseline. No change needed beyond the baseline no longer being `nil`.
- **Accent colour** continues to come from the locally-computed band. Provisional
  scores use the same band colours — the "early" qualifier is carried in the
  headline, not by desaturating the widget into looking broken.

## 6. Stability penalty phase-in

`cv7` needs 7 anchors and `cv7Stat` needs 8. Both currently degrade to a 0
penalty, which means a provisional score carries **no stability penalty** and can
drop up to 10 points on day 8 for no reason the user did anything about. That is
the exact "the number lied to me" moment this spec exists to prevent.

Phase it in with the same ν weighting rather than letting it snap on: scale the
computed stability penalty by `min(1, (n − firmAnchors) / ν)` so it ramps from 0
at n = 7 through 0.25 at n = 8 to full at n = 11. The other two penalties need no
change — `pip` needs n ≥ 2 and `dfa1Median` needs n ≥ 1, so both are live from
the start.

## 7. Server

`server/routers/insights.py:298` currently instructs the model that when
`baseline_sufficient` is false there are no norms to claim and the app is "still
learning what is normal". With a provisional score present that instruction now
contradicts the number on screen.

- `DayPotentialPayload` gains `provisional: bool`. `baseline_sufficient` keeps
  its meaning (`n ≥ firmAnchors`) so the field is not silently redefined.
- Prompt gains a third branch: score present but early. The score is real, say
  what it shows, note the range is still forming, do not over-read a single
  morning.
- Validation at `insights.py:345-349` currently rejects a score when
  `baseline_sufficient` is false. That check inverts: a provisional request
  **must** carry a score.

## 8. Testing

`PotentialScoreTests` and `AnchorBaselineTests` already exist and are the homes
for this.

**`AnchorBaselineTests`**
- `build` returns a baseline at n = 1 with `sd_blend` equal to the prior exactly.
- `provisional` is true at n = 1…6, false at n = 7.
- `sd_pred` multipliers match §2.3 within tolerance at n = 1, 2, 7, 20.
- The §2.1 worked example: n = 3, personal SD 0.05, prior 0.20 → 0.166.
- Degenerate personal SD (all anchors identical) yields a finite z, not `nil`.
- `hourMatched` stays false below 7 near-hour anchors.

**`PotentialScoreTests`**
- **Continuity at the boundary** — the same today-anchor scored against baselines
  built from the first 6 and first 7 entries of one synthetic series differs by
  **≤ 3 points**. This is the test that protects the core promise; if the label
  change is visible as a number jump, the design failed.
- Stability penalty is exactly 0 at n = 7, which is what makes the above hold —
  the penalty ramp and the label change must not land on the same day.
- Stability penalty is 0 at n = 7, full at n = 10, monotonic between.
- An identical anchor repeated daily converges toward 50 as n grows.
- Existing saturation-guard and penalty-cap tests still pass unchanged.

**Server** — `test_insights.py` gains provisional-branch cases: request with
`provisional=true` and a score validates; `provisional=true` without a score is
rejected.

---

## Out of scope

- Re-tuning `wLnRMSSD` / `wDC` / `wRestingHR`. Untouched.
- Anchor detection thresholds. Untouched.
- Per-user learned priors. The fixed constants are deliberately the simple
  version; revisit only if calibration data says they are wrong.
