# Track — Macro Trends

**Date:** 2026-07-28
**Status:** Design approved; pending implementation plan
**Scope:** Rebuild the Track tab as a period-based macro-trend view — W / M / 6M bar charts of seven key metrics against a personal baseline, an LLM macro read, and a consistency card. Replaces `HistoryView.swift`.

---

## Goal

Track answers one question: **are my key metrics moving in the right direction across days, weeks, and months?**

Today it answers a different one — it opens on a live snapshot, splits into HRV/TRAIN tabs, charts raw tech names (SDNN, LF/HF, pNN50, ULF) as dot-and-line series, and ends in a list of auto-created strap sessions. The rework drops all of that.

## Starting state

`ios/Wythin/UI/History/HistoryView.swift`, 645 lines: NOW rings → HRV/TRAIN tab picker → 7D/30D/90D window picker → eight `LineMark`+`PointMark` charts → HRV session list → Train session list.

### Bug this rework must fix

`HistoryView.swift:194-198` fetches raw `HRVSample`s:

```swift
var desc = FetchDescriptor<HRVSample>(
    predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
    sortBy:    [SortDescriptor(\.timestamp)]
)
desc.fetchLimit = 200_000
```

All-day background recording writes a tick every ~2 s (`AppEnvironment.swift:464`) — 43,200 rows/day. `fetchLimit = 200_000` with an **ascending** sort therefore returns the oldest ~4.6 days of the window. The 30D and 90D charts today render only the first few days of their range and silently drop the rest. Six months of raw samples would be ~7.8M rows, so the approach cannot be scaled; it must be replaced.

### Reused, not rebuilt

`activityMetricDefs` (`ios/Wythin/UI/Activities/ActivityMetricsGrid.swift:49`) already defines all nine metrics with friendly label, tech label, unit, `BenefitDirection`, extractor, formatter, and a hand-written `why` blurb. Track's current charts use raw tech names and have drifted from it. The new Track consumes this registry so the two views cannot diverge again.

`POST /v1/insights` (`server/routers/insights.py:345`) already branches on `mode` for `activity` / `live_state` / `day_potential`, and `_METRIC_NAMES` (`insights.py:220`) already maps every metric key to a human-readable gloss. The macro read is a fourth mode on the same endpoint, not a new one.

## Decisions

| Question | Decision |
|----------|----------|
| Screen structure | Flat — no NOW section, no HRV/TRAIN tabs. Period toggle → macro read → 7 charts → consistency card. |
| Periods | **W** (7 daily bars), **M** (~30 daily bars), **6M** (6 monthly-average bars). Prev/next paging plus horizontal swipe. |
| Metrics | The 7 from `activityMetricDefs` excluding Pulse and Calm Power. |
| Chart form | Bars with the value printed on top, not dots and lines. |
| Reference line | The user's own 90-day median per metric, falling back to a fixed physiological norm below 14 days of data. |
| Recommendations | One LLM macro read at the top per period; under each chart a computed one-liner plus the metric's existing `why`. |
| Rollup storage | JSON file in Application Support — a derived cache, not a SwiftData model. |
| HRV session list | Removed. Replaced by a consistency card (practice + wear). |
| Train sessions | Move to `PracticeHubView`. |

---

## Block 1 — Daily rollup cache

One record per local day, computed once, reused by every period:

```swift
struct DailyRollup: Codable {
    let day: Date              // start of local day
    let dc, rmssd, rsaMs, rcmse, pip, dfa1, stressBalance: Double?
    let vti, meanBPM: Double?  // stored though unused by the 7 charts — cheap, keeps options open
    let sampleCount: Int
    let wearSeconds: Double
}
```

**Storage.** A single JSON file in Application Support, loaded whole into memory. ~180 days × 12 floats is a few hundred KB.

Not SwiftData. Three reasons: the cache is derived and always rebuildable; it is small enough to hold in memory entirely, so queries buy nothing; and adding a `@Model` to the schema risks tripping the `catch` at `WythinApp.swift:21`, which deletes the entire store on migration failure. A convenience cache must not share a fault line with the user's history.

**Computation.** Incremental and day-scoped. For each day in the requested range with no cached row:

1. Fetch that day's `HRVSample`s only (≤ ~43k rows — bounded memory, no global fetch limit).
2. Apply the existing `MetricsQualityFilter`.
3. Gate: a day needs ≥ 150 quality ticks (5 minutes) to produce a row, matching today's rule.
4. Average each field; accumulate `wearSeconds` from the retained tick count.

Past days are immutable once written. Today's row is recomputed on every Track appear. The first open of a long range spins only on the days it is missing; afterwards it is instant.

**Stress Balance** has no stored field. It is derived per tick via `AutonomicCompute.balance(rmssd:lf:hf:breathBPM:meanBPM:baselineRmssd:)` — the same call `ActivityMetricsGrid.swift:58` makes — then averaged into the rollup.

**Aggregation.** W and M: one bar per day, the day's mean. 6M: one bar per calendar month, the **unweighted** mean of that month's daily means, so an 18-hour wear day cannot outweigh a 6-hour one. A month with fewer than 5 valid days renders as an absent bar rather than a misleading one.

**Baseline.** Median of the last 90 daily rollups for that metric, recomputed daily. Below 14 valid days it falls back to the metric's fixed physiological norm and the chart label reads `typical` instead of `your 90d`.

**Range fingerprint.** A stable hash of the rollup *values* covering a given range. Used to key the macro-read cache (Block 3). It must be a value hash, not a write counter: today's row is rewritten on every Track appear, so a write counter would invalidate the cache constantly and re-bill an LLM call each time the screen is opened.

## Block 2 — The screen

### Top bar (sticky)

Row 1: `TRACK` title, with a `W · M · 6M` capsule segmented control right-aligned, reusing the accent-pill style from the current `windowPicker`.
Row 2: `‹ JUL 21 – JUL 27 ›` in dim monospace. The forward arrow is disabled at the current period. Horizontal swipe on the content pages periods.

### Composition

Macro read card → 7 metric cards → consistency card.

### Metric card

```
VAGAL TONE  DC                          8.4 ms
▲ 6% vs prior week                      AVERAGE

  7.9  8.1  9.2  8.8  7.4  9.0  8.9
┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ 8.2 your 90d
  ▇    ▇    █    █    ▆    █    █
  M    T    W    T    F    S    S

5 of 7 days above your baseline.
Your vagal brake — how readily the heart slows.
```

**Order:** Vagal Tone, Energy Reserve, Conscious Breathing, Adaptive Capacity, Harmony, Inner Noise, Stress Balance — recovery first, load last.

**Header:** friendly label, dim tech label, period average in the metric colour on the right with a small `AVERAGE` caplabel beneath.

**Delta chip:** benefit-signed via `BenefitDirection` from `activityMetricDefs`, so a *fall* in Inner Noise reads as an improvement. Compared against the immediately preceding period of equal length. Absent when the prior period has no data.

**Bars:** rounded-top `BarMark` in the metric colour, ~60% of the slot wide. Days below the reference drop to 0.45 opacity so the line reads at a glance. No y-axis labels — the numbers are on the bars. Missing days show a dim `·` on the axis and no bar.

**Y-domain:** zero-based for magnitude metrics (Energy Reserve, Vagal Tone, Conscious Breathing, Inner Noise, Stress Balance). **Baseline-anchored** for index metrics (Adaptive Capacity, Harmony) at reference ± 1.6× the observed spread — a zero-based chart of values hovering near 1.0 is a wall of identical bars.

**Selection:** tapping a bar swaps the header to that day's value and date and highlights the same day across all 7 charts. The current implementation's shared `selectedDay` binding carries over — it is its best feature.

**Below the chart:** one computed line (`5 of 7 days above your baseline`, counted in the benefit direction) and the metric's `why` from `activityMetricDefs`, so the copy cannot drift from the Activities view.

### Label density by period

| Period | Bars | Numbers |
|---|---|---|
| W | 7 daily | every bar |
| M | ~30 daily | min, max, and most-recent only — **plus 4 weekly-average segments** drawn as short horizontal rules with their value |
| 6M | 6 monthly | every bar |

Thirty bars across ~350pt is ~11pt per bar; a number on every one is unreadable. The weekly-average overlay is what makes the month view legible, and it matches the reference screenshot's idiom.

### Consistency card

Two rows in one card, both scoped to the current period:

```
CONSISTENCY — this week
PRACTICE   6 sessions   72 min   🔥 4-day
  12   ·   18   9   ·   15   18
  ▆    ·   █    ▄   ·   ▇    █

WEAR       avg 14.2 h/day
  16   15   4   17   13   9   18
  █    █   ▂   █    ▆    ▅   █
  M    T   W   T    F    S   S
```

Practice comes from `ActivityLog` — deliberate, logged practice. It deliberately does **not** come from `HRVSession`: those are auto-created for background all-day recording (`AppEnvironment.swift:464`), so the current "HRV SESSIONS" list is strap wear time mislabelled as practice. That is why it reads as unhelpful.

Wear is `wearSeconds` from the rollups. It earns its place by explaining gaps and thin bars in the charts above — without it, a missing day looks like a physiological event rather than a day the strap was off.

Streak reuses `StreakCompute`.

## Block 3 — Macro read

A fourth mode on `POST /v1/insights`.

**Request.** `mode: "macro_trend"`, plus `period` (`week` | `month` | `six_month`), `range_label`, and:

```python
trends: dict[str, MacroTrend]
# MacroTrend: {avg, baseline, delta_pct, days_above, days_total, direction}
# delta_pct is benefit-signed — positive always means improvement, including
# for metrics where the raw value fell (Inner Noise, Stress Balance).
```

Keys are the existing metric keys — `dc`, `rmssd`, `rsa`, `rcmse`, `pip`, `dfa1` — so `_METRIC_NAMES` glosses six of the seven without change.

Stress Balance needs **a new key `stress_balance`, added to `_METRIC_NAMES`**. It must not be sent under `lf_hf`: the existing gloss describes a raw LF/HF ratio, whereas the value the app computes is the breathing-robust 0–100 dial from `AutonomicCompute.balance`. Reusing the key would have the model interpret a percentage as a ratio.

**Prompt.** Follows the `day_potential` discipline: exactly two sentences reading the period, then one or two actions prefixed `→`. The model never states or recomputes a number the app did not send. `max_tokens` ≈ 180, one call per period.

**Validation.** 422 when `trends` is absent or empty.

**Privacy.** Only aggregate daily means leave the device — never raw samples. No new consent surface; this is the same endpoint activity insights already use.

**Caching.** Stored in the same JSON file as the rollups, keyed by `period + range start + cache revision`. Paging back to a past week is instant and free; the current week regenerates only when its underlying rollups change.

**Failure.** The card is simply absent — no error toast — and is retried on the next appear.

## Block 4 — Train relocation

`TrainSessionRow` moves verbatim into a `HISTORY` section on `PracticeHubView`. No behaviour change, only relocation. Track keeps no session lists of any kind.

---

## Files

`HistoryView.swift` is deleted rather than extended. The new screen carries roughly four times the logic and 645 lines was already the ceiling.

**New**

| File | Purpose |
|---|---|
| `ios/Wythin/Metrics/DailyRollup.swift` | `DailyRollup` + `DailyRollupCache`: load, save, compute missing days, cache revision |
| `ios/Wythin/Metrics/TrackPeriod.swift` | period enum, range math, bucketing, axis labels — pure |
| `ios/Wythin/Metrics/TrackSeriesBuilder.swift` | rollups + period → bars, average, benefit-signed delta, baseline, "N of M" line — pure |
| `ios/Wythin/Metrics/TrackMetricSpec.swift` | wraps `ActivityMetricDef`, adds `rollup` / `zeroBased` / `fallbackReference` |
| `ios/Wythin/UI/Track/TrackView.swift` | screen shell |
| `ios/Wythin/UI/Track/TrackPeriodBar.swift` | W·M·6M toggle + range navigator |
| `ios/Wythin/UI/Track/TrackMetricChartCard.swift` | the bar chart |
| `ios/Wythin/UI/Track/MacroReadCard.swift` | LLM card + fetch |
| `ios/Wythin/UI/Track/ConsistencyCard.swift` | practice + wear |

`TrackMetricSpec` *wraps* rather than extends `ActivityMetricDef` because that type is consumed by the Activities grid and charts; adding Track-only chart fields to it would push presentation concerns into a shared model. Labels, units, direction, and `why` stay single-sourced.

**Changed**

- `ios/Wythin/App/WythinApp.swift` — route the Track tab to `TrackView`
- `ios/Wythin/UI/Train/PracticeHubView.swift` — gains the train-session history section
- `ios/Wythin/Sync/APIClient.swift` — `MacroTrendPayload` + `generateMacroTrendInsight`
- `server/models.py` — `MacroTrend`, macro-trend fields on `InsightRequest`
- `server/routers/insights.py` — fourth mode branch, prompt, formatter

**Deleted**

- `ios/Wythin/UI/History/HistoryView.swift` — with it `TrackTab`, `TrackWindow`, `TrackMetric`, `DailySummary`, `TrackDailyChartCard`, `SessionRow`. `TrainSessionRow` moves to Train.

## Error handling

| Case | Behaviour |
|---|---|
| One day's rollup fails to compute | That day is absent; every other day renders |
| No valid data in the period | Per-card "No data this period"; macro read card hidden |
| Macro read request fails | Card hidden, no toast, retried on next appear |
| Cache file corrupt or unreadable | Deleted and rebuilt silently |
| Prior period has no data | Delta chip omitted, average still shown |
| Fewer than 14 valid days | Reference line uses the fixed norm, labelled `typical` |

## Testing

The three pure types carry the real logic and get real coverage in `ios/WythinTests`:

**`TrackPeriodTests`** — week/month/6M range math across DST transitions and short months; prev/next paging; clamping at the current period.

**`TrackSeriesBuilderTests`** — bucketing with missing days; monthly mean-of-day-means is unweighted; a month with <5 valid days is suppressed; benefit-signed delta for `.lower` and `.target(1.0)` directions; delta omitted when the prior period is empty; baseline median falls back to the fixed norm below 14 days; "N of M above baseline" counts in the benefit direction.

**`DailyRollupTests`** — the ≥150-tick gate; stress-balance derivation and averaging; today's row recomputes while past rows do not; `wearSeconds` accumulation; corrupt cache file rebuilds.

**`server/tests/test_insights.py`** — macro_trend mode 422s without `trends`; happy path against a stubbed OpenAI client, following the existing patterns.

## Out of scope

- Server-side rollups (the cache is on-device only)
- A full-screen per-metric detail view
- Custom / arbitrary date ranges
- Export
- Pulse and Calm Power charts
