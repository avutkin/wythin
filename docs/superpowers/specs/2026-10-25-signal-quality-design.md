# Signal quality on the dashboard

**Date:** 2026-10-25
**Status:** built, this session

## Problem

A night on 2026-10-24 read ~160 bpm with RMSSD ~150 ms for ten hours — a
combination that cannot happen in a real body (a pulse that fast and a
variability that large do not coexist). Diagnosing it took SSHing into the
box and hand-querying raw tables, because the server had nothing: the
on-device read of how trustworthy a tick is — `signalQuality`,
`rrInvalidRate`, `ecgQualityTier` (`SignalQualityTier`: 0 poor … 2 good) —
never left the phone. `metric_samples` carried fourteen metric columns and
`motion`; nothing said whether the numbers behind them could be trusted.

## Design

Sync the three fields the same way `motion` was synced in September:
upload, store, serve, restore. Then show them where a reader is already
looking when something seems wrong — the activity's KPI row and the
night's montage.

### iOS

- `HRVSample` / `MetricsHistoryPoint` already carry the three fields from
  live computation; only the wire path was missing.
- `MetricSamplePayload` / `MetricExportSample` (`APIClient.swift`) gain
  `signal_quality`, `rr_invalid_rate`, `ecg_quality_tier`.
- The upload-building call and `CloudRestoreService.insert` carry them
  through; `HRVSample.init(cloudTs:)` gains the three as optional
  parameters, following the precedent its own doc comment set for `motion`.

### Server

- `metric_samples` gains `signal_quality REAL, rr_invalid_rate REAL,
  ecg_quality_tier SMALLINT`, additive migration.
- `routers/metrics.py`'s `_COLS` list drives insert and export generically,
  so adding three names there is the whole change on that side.
- `routers/admin.py`'s `activity_series` appends the three columns to what
  it already appends `motion` to, so a night's (or any activity's) tick
  series carries bucket-averaged quality alongside everything else.

### Dashboard

- **Signal quality KPI tile**, present for every activity type, not only
  sleep — a short meditation can have as bad a strap fit as a long night.
  Shows % good / okay / poor among tiered ticks and the mean invalid-RR
  fraction, colored by the dominant tier.
- **Montage lane**, sleep only, placed right after Movement and before the
  scored metric groups — read first, because it explains the traces below
  it. One rect per tick colored by tier, so a short bad stretch is never
  averaged into an innocent-looking blur, the way a bucketed line would.
- A bucket is "good" only once its average sits mostly in the good tier,
  and "poor" only the same way at the other end — `v >= 1.5` / `v <= 0.5`
  on the 0–2 average; the middle band is "okay". Shared between the KPI
  tile and the lane so the two numbers can never disagree.

## Out of scope

Filtering poor-quality ticks out of the sleep score itself — that changes
what the score means and is a separate, on-device decision. This round is
visibility only: the reader can now see a bad stretch and discount it by
eye, the way the KPI tile and the lane both do for the diagnosed night.
