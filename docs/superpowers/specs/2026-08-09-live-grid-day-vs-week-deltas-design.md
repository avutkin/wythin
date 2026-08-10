# Live grid: percent-first tiles, today vs the last 7 recorded days

**Date:** 2026-08-09
**Status:** approved (brainstormed via visual companion, final mockup `live-grid-simple.html`)

## What changes

The LIVE metrics grid (9 tiles in `MetricsTableView`) stops showing a raw
`live − todayAvg` unit delta and becomes percent-first:

- **Hero number**: signed % of **today's average vs the reference week**
  (the last 7 recorded days). Colored and washed by how unusual the shift is.
- **"now" chip** (top-right, today only): signed % of the **live reading vs
  today's average**, quiet by design (small, capped intensity).
- **Footnote**: the three absolute values spread across the tile bottom:
  `now 32.2 · today 37.0 · 7d 41.2`.
- **Header**: right-side label becomes `today vs 7-day` (past days: `vs 7-day`).
- Past-day pages get the same treatment: the day's average vs the 7 recorded
  days before *that* day; no "now" chip.

## Reference week

The last **7 days strictly before the viewed day** whose rollup has
`wearSeconds ≥ 30 min`. The lookback extends as far as the rollup cache goes
(~180 days) — unrecorded days are skipped, not counted. Fewer than **2**
qualifying days → no comparison (tile shows the live value as before, no wash).

Per-metric centre and spread over those days reuse the `LiveBaseline` math:
centre = unweighted mean of daily means; spread = pooled within-day SD weighted
by that metric's per-day sample count; z via `BaselineStat.z` with `LivePrior`
blending. New pure helper: `LiveDayComparison` + `LiveDayReference` +
`LiveDayDelta` in `ios/Wythin/Metrics/`.

## Color logic

- Direction per metric uses the canonical `BenefitDirection`
  (`.higher/.lower/.target`) — Harmony (DFA α1) is `.target(1.0)`, fixing the
  old `higherBetter: false` mismatch. Green = beneficial move, red = adverse;
  the arrow still shows the raw direction of the number.
- Magnitude is z-scaled, not %-scaled: `|z| < 0.5` → neutral (plain dark tile,
  gray `≈ +1%`); above that, wash/text intensity ramps linearly from 0.35 at
  `|z| = 0.5` to 1.0 at `|z| = 2`.
- The "now" chip: gray when `|now%| < 5`, otherwise benefit-colored at reduced
  opacity. Never washes the tile.

## Code shape

- `Metrics/LiveDayComparison.swift` — day selection, reference stats, delta
  computation, per-metric `BenefitDirection` mapping. Pure; unit-tested
  (qualifying-day selection, min-days gate, % math, target-direction sign,
  z→intensity mapping, zero-mean guard).
- `UI/Live/LiveDeltaTile.swift` — new tile view (percent hero, chip, footnote,
  graded wash). `MetricTile` stays untouched for the Activities peak mode.
- `LiveView.swift` — `MetricsTableView` takes the reference and renders
  `LiveDeltaTile`s from a per-metric config; `DayScrollView` builds the
  reference from `env.trackCache` alongside the existing `chartDayAvg`.

## Out of scope

Sparklines, baseline ribbon (explored, rejected for simplicity), per-metric
weights, changes to rollup computation or the 60-day `LiveBaseline` used by
the state widget, nudges.
