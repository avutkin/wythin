# Exercise Response Model — Design

**Date:** 2026-07-31
**Status:** Design approved, ready for implementation planning
**Scope:** The Exercise activity type only. Meditation, Breathwork, Meal, Nap, Thermal, Drinks, Work and Custom are untouched at every phase.

---

## 1. Problem

Every activity is scored by one rule: the mean benefit-signed change across nine restorative
metrics (`ActivityLog.impactDeltaPct`, `ActivityImpact.score`). Exercise raises heart rate and
suppresses variability by design, so a hard session posts a large negative number **by
construction**. The app currently tells the user their best training was their worst day.

The nine metrics are also wrong for exercise individually:

- `Harmony` uses `.target(1.0)` for DFA α1. During exercise, α1 near 1.0 means you were barely
  working. The direction is inverted for this context.
- `Inner Noise` (PIP) and `Adaptive Capacity` (RCMSE) assume stationarity. Under exercise they
  largely measure artifact.
- `Stress Balance` (LF/HF-derived) is not a sympathovagal index.
- `Calm Power` (VTI) is `ln(RMSSD)` — redundant with `Energy Reserve`.
- `SDNN` under exercise tracks the HR trend, not variability.

Walk is a separate top-level type but is the same phenomenon at lower intensity, and it consumes
one of the nine picker tiles.

## 2. Approach

Replace the single impact percentage for Exercise with **one descriptive magnitude (Load) and
three directional axes (Suppression, Recovery, Efficiency)**, computed from four core signals.
The axes are never averaged.

### 2.1 Activity classification

New `ActivityClass` with two cases:

| Class | Types |
|---|---|
| `.activating` | `.exercise` (now including all former Walk subtypes) |
| `.restorative` | everything else |

The class selects the list row and the detail view. Restorative sessions never enter new code
paths.

### 2.2 Walk merge

- `ActivityType.walk` is removed from `pickerCases`, freeing a tile in the nine-tile grid.
- Its four subtypes (`Nature Walk`, `City Walk`, `Hiking`, `Treadmill`) join `.exercise.subtypes`.
- `ActivityType.fromStored("Walk")` returns `.exercise`, following the existing migration path
  used for `Run`, `Cold Exposure`/`Sauna` and `Coffee`/`Alcohol`. Historical entries keep their
  own subtype label; only the tile they group under changes.
- A walk is simply a low-Load, low-Suppression session. No special-casing.

## 3. Signals

Four core, two supporting. All are already captured per `HRVSample`; nothing new is measured.

| Signal | Role | Rationale |
|---|---|---|
| `meanBPM` | load axis | ~8 s median, effectively instantaneous. Drives onset kinetics, HRR, load impulse and work/break segmentation. |
| `dc` | the vagal brake | PRSA isolates the deceleration side, measuring vagal withdrawal rather than a sympathovagal blend. |
| `dfa1` | intensity domain | An internal threshold marker, independent of HRmax, fitness and resting HR. |
| `rmssd` (as `lnRMSSD`) | recovery | Fastest-responding vagal index post-exercise, with published comparison values. |
| `motion` | external-load proxy | The only non-cardiac signal available. Enables Efficiency and separates work from break. |
| `rsaMs`, `breathBPM`, `ieRatio` | breathing quality | Trustworthy in breaks and after only — see §7.3. |

**Dropped from scoring (still visible under `▸ Raw metrics`):** PIP, RCMSE, LF/HF-derived Stress
Balance, VTI, SDNN.

**Explicitly not included: SpO₂.** The Polar H10 has no optical sensor. The only route is Apple
Watch via HealthKit — spot readings, unreliable during motion. Even with perfect data, SpO₂ sits
at 95–98 % at sea level and barely moves; it is informative only at altitude, in deliberate
hypoxic training, or in respiratory disease. Revisit only if altitude training becomes a feature,
and then as its own sensor decision.

## 4. Load

The descriptive magnitude. Replaces the benefit percentage on the list row.

```
x_i  = (HR_i − restingHR) / (HRceiling − restingHR)      clamped to [0, 1]
Load = Σ  x_i · e^(1.8 · x_i) · Δt_i                      Δt in minutes
```

- `restingHR` from `AnchorBaseline.restingHR.mean`.
- `HRceiling` from a new `HRCeiling` helper: the 99th percentile of `meanBPM` over 180 days,
  floored at `restingHR + 60`. Self-calibrating — no age input, no 220-minus-age.
- `b = 1.8` is a fixed compromise between Banister's sex-specific 1.92 / 1.67. It may become a
  profile setting later; it is not one now.

Reference range: an easy 30-minute walk lands near 14, a hard hour near 150.

**Load carries the size of the stimulus, so no axis has to.** This is what allows all three axes
to point the same way (higher is better).

## 5. The three axes

### 5.1 Suppression (VSI)

*How deeply the vagus had to be switched off for this load.* Normalised by **internal** load.

```
VSI = slope( lnDC ~ %HRR )     reported as lnDC per 10 %HRR
```

Fitted by linear regression across all **work-bout** samples below the severe threshold. Not a
single trough-vs-peak ratio: a ratio discards the session and breaks at high intensity.

**Severe-domain exclusion is mandatory.** Above the α1 < 0.5 boundary (≈ 84 %HRR for most users,
but determined per session from α1, not from %HRR) DC floors near zero — the denominator keeps
climbing while the numerator physically cannot. A ratio taken across that region measures the
ceiling, not the person. The excluded band is drawn on the chart rather than silently dropped.

**Score:** the fitted slope's percentile against the user's own last 90 days of the same subtype,
inverted so a shallower slope (cheaper) scores higher. Reported alongside the raw slope and the
percentage difference from the personal line.

**Supporting readouts in the same card** (not scored):
- `τ_on` — seconds until HR reaches 50 % of session amplitude. The first 30–60 s of HR rise *is*
  vagal withdrawal, so this measures how fast the brake released.
- Raw depth — `1 − DC_trough / DC_pre`, trough = 10th percentile across work bouts. Labelled
  Minimal / Moderate / Deep / Maximal. Descriptive only.
- **Stability** — rolling correlation between HR and the vagal trace (coupling tightness) and the
  break decay slope (§6.2). Tight coupling means the autonomic response tracked load smoothly;
  erratic is the fatigue signature. This is where low-motion modalities recover the information
  they lose in Efficiency.

**Fallbacks:** if DC fails quality gating, substitute `lnRMSSD`. If the pre-window is thin, use
`AnchorBaseline.dc.mean`.

### 5.2 Recovery

*How fast and how completely the brake came back.* Progressive — it exists at 60 seconds and
firms up over the following hours.

Weighted composite of the checkpoints that have arrived, renormalised over those present:

| Checkpoint | First read | Weight | Definition |
|---|---|---|---|
| `T30` | 30 s | 0.10 | Negative reciprocal of the slope of a linear regression of ln(HR) on time over the first 30 s. Pure HR — no HRV, so no artifact sensitivity. |
| `HRR60` | 60 s | 0.25 | HR at session end minus HR at +60 s. Linear interpolation between bracketing samples; requires a sample within ±20 s of target. |
| `DC@90s` | ~90 s | 0.15 | Detrended DC as a fraction of `DC_pre` (§7.1). |
| `HRRτ` | 3–6 min | — | Mono-exponential fit of HR decay. Reported, not weighted (correlated with T30/HRR60). |
| reactivation % | 10 min | 0.20 | `DC_10min / DC_pre`. Published comparators shown alongside: yoga ≈ 48 %, resistance ≈ 28 %, aerobic ≈ 21 %. |
| α1 0.75-crossing | 15–60+ min | 0.15 | Minutes from session end until α1 climbs back through 0.75. |
| time-to-baseline | ≤ 4 h | 0.15 | First sustained (≥ 5 min) return of `lnRMSSD` to within 0.5 SD of the pre-session window. Reported as `> 4 h` when not reached. |
| next anchor | next morning | — | Tomorrow's anchor z vs the 60-day baseline. Drives the recommendation, not the score. |

**Each component is scored against the user's own recovery at comparable load**, using load-quartile
bands from their own history. Without this conditioning Recovery is Load with the sign flipped,
the axes collapse to one line, and the session map loses its second dimension.

The cascade ladder displays **seven arrivals** (the six weighted checkpoints plus the next-morning
anchor); the score is computed from the six that carry weight. UI shows `provisional · k of 7`
until four weighted checkpoints have landed, then `firming`, then the final word.

**Gate:** `HRR60` and `T30` are only computed when the session ended at meaningful intensity —
final-minute HR ≥ `preHR + 30 %` of session amplitude. A yoga cooldown has no HRR; the field reads
`—` rather than a misleading small number.

### 5.3 Efficiency

*How much autonomic activation it took to do the same **mechanical** work.* Normalised by
**external** load.

```
Efficiency_raw = slope( lnDC ~ work )
```

where `work` is a motion impulse: `Σ (motion_i / motion_ref) · Δt` across work bouts.

**Score:** percentile against the user's own last 90 days of the same subtype, inverted.

**Two ways to be honestly empty, stated differently:**

| Condition | Display |
|---|---|
| Fewer than 3 prior sessions of the subtype | `— · 1 of 3` |
| No valid external work signal for the modality | `— · no ext. signal` |

Suppression and Efficiency differ **only** in the denominator, so Efficiency must never fall back
to heart rate — that would make it Suppression computed twice. Chest-strap motion is a fair proxy
for running, walking, hiking, rowing and boxing; it is a bad one for lifting, yoga, cycling and
swimming, where a heavy single moves less than a light set of ten. Those modalities show
`no ext. signal` and get Stability instead (§5.1).

**Out of scope, noted as follow-up:** importing HealthKit workouts would supply real pace and
power and make Efficiency universal. Not in this spec.

## 6. Session structure

### 6.1 Segmentation

`SessionSegmenter` partitions the session into work bouts and breaks:

- **Work bout:** `motion` above the session's own motion floor **and** HR held above
  `preHR + 40 %` of amplitude.
- **Break:** `motion` below floor for ≥ 20 s **and** HR falling.
- Hysteresis plus minimum durations (work ≥ 20 s, break ≥ 15 s) so the series does not shatter
  into noise.
- A steady run collapses to one long bout. That is the correct answer for a steady run, and the
  break ladder is simply absent.

### 6.2 Break quality

Per break: HR drop rate (bpm/min), vagal rebound (did `lnRMSSD`/DC rise, by how much),
completeness (fraction of the way back toward `preHR`), and breath rate + I:E ratio (§7.3).

The session number is the median. **The decay slope across breaks is the more informative
quantity** — later breaks clearing less than earlier ones means load is accumulating faster than
it is being cleared, readable set by set. It feeds Stability and the coach copy.

## 7. Correctness requirements

### 7.1 DC detrending during recovery — mandatory

During rapid HR recovery, RR rises monotonically, so nearly every beat is a deceleration. PRSA
will average that trend into DC and inflate it into a meaningless number.

`AdvancedHRVCompute.computeDC` gains a `detrend:` parameter. The recovery-phase path linear-detrends
the RR series inside the window before running PRSA; the resting-phase path is unchanged.

**Required test:** feed a synthetic monotonic RR ramp with no vagal oscillation. Undetrended DC
must be large; detrended DC must be ≈ 0. Without this, DC-based recovery is not noisy — it is wrong.

### 7.2 DC window arithmetic

`computeDC` requires 150 RR intervals and ≥ 20 deceleration anchors. The requirement is in **beats,
not seconds**. At a post-exercise HR of 140 bpm, 150 beats arrive in ~64 s of wall clock versus
~150 s at rest. DC is therefore *faster* after exercise than at rest and is viable as an early
recovery index.

### 7.3 Breathing scope

`BreathingCompute.computeRate` runs a Welch PSD over accelerometer Z (0.08–0.50 Hz). Body motion
swamps that band during work, so `breathBPM` and `ieRatio` are read **only in breaks and after** —
the same rule already applied to RSA.

Respiratory frequency follows perceived exertion more closely than heart rate does, which would
make it valuable during work too. That requires ECG-derived respiration (R-wave amplitude
modulation) rather than accelerometry. **Out of scope, noted as a separate investigation.** If it
lands, it unlocks the ventilatory-drift signal: fR climbing while HR plateaus.

### 7.4 Sampling cadence

Ticks are 2 s in foreground, 30 s in background. `HRR60` and `T30` interpolate between bracketing
samples and require a sample within ±20 s of target; otherwise the checkpoint is absent rather than
approximated.

## 8. Presentation

### 8.1 List row (`ExerciseLogRow`)

Header keeps icon, name, time and duration. The right-hand badge becomes **Load**. Below it a
sparkline (the session timeline shrunk, showing the work-break rhythm) and three chips —
SUPPRESSION, RECOVERY, EFFICIENCY — each with a 0–100 value and a one-word read.

All three chips point the same way: higher is better. The word does the interpreting
(*cheap*, *typical*, *costly late*).

Restorative rows keep the existing 3×3 grid, unchanged.

### 8.2 Live banner

Two additions to the existing banner:

- **Domain pill** — `MODERATE` / `HEAVY` / `SEVERE`, live from α1 at the 0.75 and 0.5 boundaries.
- **Break coach** — takes over the banner when the segmenter detects a rest. Shows bpm/min
  clearing, a comparison against earlier breaks this session, and breath rate + exhale:inhale.
  A break is the one place chest accelerometry is trustworthy, which turns "slow the exhale" from
  advice into a number the user can move within seconds.

### 8.3 Detail view (`ExerciseDetailView`)

In order:

1. **Session timeline** — %HRR and % vagal withdrawn on one normalised 0–100 axis, work/break bands
   behind, the area between the curves filled. The gap is the vagal cost of that moment's heart
   rate: VSI as a time series.
2. **Intensity domain bar** — stacked, time under each α1 threshold, with 2 px separations and
   direct labels.
3. **Suppression card** — the VSI scatter (lnDC against %HRR) with this session's fit and the
   90-day line behind it: VSI as a slope. Plus τ_on, depth, coupling, break decay.
4. **Recovery card** — the cascade ladder, filling in as checkpoints arrive, with the α1-vs-HR gap
   called out.
5. **Efficiency card** — the break ladder with its decay trend line.
6. **Session map** — §8.4.
7. **Coach** — §9.
8. `▸ Raw metrics (9)` — the existing nine rows, unchanged, behind a disclosure.

### 8.4 Session map

A 2×2 placement, not a grade. Stimulus (`0.6 · pct(Load) + 0.4 · Suppression_raw`) against
Absorption (the Recovery score). The current session is a bright dot; the last 30 sit behind it
faintly. Quadrant boundaries are the user's own medians, so the map is personal and always
populated; absolute defaults apply below 10 sessions.

| | Slow absorption | Fast absorption |
|---|---|---|
| **High stimulus** | COSTLY — big day, take tomorrow easy | CLEAN STIMULUS ★ — pushed hard, took it well |
| **Low stimulus** | CARRYING FATIGUE — you arrived tired | EASY DAY — exactly what it should be |

The bottom-left quadrant indicts the readiness that preceded the session, not the session. No
workout is ever labelled bad.

### 8.5 Records

Only quantities that improve with fitness and degrade with overreaching:

- Biggest clean stimulus — deepest suppression that still recovered inside the normal window
- Fastest HRR60 at or above a given load
- Best efficiency for a subtype
- Longest heavy-domain time with α1 back above 0.75 within the usual span

Deliberately **no** highest-HR and **no** deepest-suppression record.

### 8.6 Trends

Efficiency per subtype over weeks (the adaptation signal), recovery speed over months, domain
distribution by week (grey-zone drift), and the session map filling in.

### 8.7 Copy rules

Load and raw depth are descriptive only. Recovery is the sole axis with a good/bad direction, and
slow recovery always arrives attached to a concrete next action rather than a judgement. Nothing
is labelled "poor". Provisional states say so rather than guessing.

## 9. Recommendation engine

`ExerciseRecommendation` — deterministic rules, first match wins. The existing `InsightGenerator`
handles phrasing; the rule engine decides what is said.

Inputs: readiness band (before, from `PotentialScore` / `AnchorBaseline`), Load percentile and
domain distribution (during), Recovery score and next-morning anchor z (after), 7-day rolling Load
and 7-day mean Recovery.

1. next-morning anchor z ≤ −1.5 SD, **or** Recovery < 30 with Load pct > 75 → **Recover**
2. 7-day Load in top decile **and** 7-day mean Recovery falling → **Deload**
3. Recovery ≥ 70 with Load pct ≥ 75 → **Absorbed · repeatable in 48 h**
4. Readiness *Depleted* going in, with Load pct > 50 → **You arrived tired**
5. > 80 % heavy domain across 7 days → **Grey zone · add a genuinely easy session**
6. Efficiency trending up over 8 weeks → **Adaptation** (celebratory)
7. otherwise → **Steady**

## 10. Readiness (before)

No new computation. Reuse `PotentialScore` / `AnchorBaseline`: pre-window HR vs
`restingHR.mean`, pre-window `lnRMSSD` z, pre-window DC z. If the 5-minute pre-window shows motion
above the stillness floor (already warming up), fall back to the day's anchor.

Output is a band — Prepared / Neutral / Depleted — plus the intensity ceiling it justifies. It is
an input to the recommendation, not a score of the session.

## 11. Architecture

**New, pure and unit-tested:**

| File | Responsibility |
|---|---|
| `Metrics/ActivityClass.swift` | activating vs restorative |
| `Metrics/HRCeiling.swift` | personal HR ceiling from 180-day history |
| `Metrics/SessionSegmenter.swift` | work/break bouts |
| `Metrics/ExerciseIntensity.swift` | %HRR trace, α1 domain split, peak/mean |
| `Metrics/ExerciseSuppression.swift` | VSI slope, Efficiency slope, Stability |
| `Metrics/RecoveryCascade.swift` | T30, HRR60, HRRτ, DC@90s, reactivation %, α1 crossing, TTB |
| `Metrics/ExerciseResponse.swift` | assembles Load, the three axes, map placement |
| `Metrics/ExerciseRecommendation.swift` | the rule engine |

**Modified:**

- `Metrics/AdvancedHRVCompute.swift` — `computeDC(detrend:)` for the recovery path
- `Models/ActivityLog.swift` — Walk merge in `ActivityType`; new stored fields for the cascade and
  axes; backfill version 3
- `UI/Activities/ActivitiesView.swift` — extract `ActivityLogRow` into its own file (the view is
  already 502 lines) and branch on `ActivityClass`

**New UI:**

`UI/Activities/ExerciseDetailView.swift`, `ExerciseLogRow.swift`, and
`UI/Activities/Charts/{SessionTimelineChart, IntensityDomainBar, VSISlopeChart, BreakLadderChart,
RecoveryCascadeView, SessionMapChart}.swift`, plus the exercise variant of the live banner.

**Storage:** the cascade computes over hours, so its results are stored on `ActivityLog` and
refreshed by a deferred pass modelled on `InsightGenerator.flushPending`.

## 12. Phasing

| Phase | Content |
|---|---|
| 1 | Walk merge, `ActivityClass`, three axes from the windows already stored, new list row, detail view with timeline and domain bar |
| 2 | `SessionSegmenter`, break ladder, live break coach and domain pill, breathing in breaks |
| 3 | Full cascade — DC detrending, T30, extended after-window, next-morning anchor — plus session map and trends |
| 4 | Recommendation engine, and the 60-second projected time-to-baseline |

Phase 1 stands alone and ships. No phase touches restorative activities.

## 13. Open questions (deliberately out of scope)

1. **HealthKit workout import** — would give real pace and power, making Efficiency universal
   rather than motion-only. Needs its own design.
2. **ECG-derived respiration** — would make fR usable during work as an RPE proxy and unlock the
   ventilatory-drift signal. Real DSP work; needs its own investigation.
3. **SpO₂** — see §3. Only revisit if altitude or hypoxic training becomes a deliberate feature.

## 14. Visual reference

Interactive mockup of all screens and charts:
https://claude.ai/code/artifact/3be710f9-7a58-4545-8dae-fb79c3f32f8a
