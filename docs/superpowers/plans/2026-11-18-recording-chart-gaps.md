# Recording Chart Gaps Implementation Plan

> Execution: inline using superpowers:executing-plans, followed by one independent whole-change review.

**Goal:** Leave visible gaps in measured lines and fills whenever a metric has no usable readings for five minutes or longer.
**Architecture:** Segment original timestamps, then average separately by recording run and bucket in the shared MetricChartCard.
**Spec:** docs/superpowers/specs/2026-11-18-recording-chart-gaps-design.md

## Global Constraints
Five-minute threshold; preserve continuous-data lines at 24h, per-run smoothing, averaged values/metadata/transforms, fixed day/night domains and thresholds. No capture/storage/network changes. Existing isolated checkout only; preserve untracked reports/research_notes. No physical recording claim for a chart-only change.

## Review Focus
- No interpolation across a five-minute gap hidden inside one bucket or adjacent buckets.
- A stray intermediate sample or other metric cannot bridge a long missing interval.
- Genuine continuous high-cadence data still forms lines at 24h; nil values and unordered input are handled honestly.
- Line and area use matching run IDs; point identity is unique and plotted time stays inside actual coverage.
- Date bounds, pinned night spans, quality, estimated flags and transform-after-average retain their meaning.

### Task 1: Segment before averaging and verify shared charts
Files: ios/Wythin/UI/Live/MetricsChartsView.swift; ios/WythinTests/ChartSegmenterTests.swift.
Interfaces: ChartSegmenter.segments(timestamps:gapBreakSeconds:) returns a run per sorted sample; MetricChartCard.points buckets by run and time; ChartPoint.id is the first contributing sample date.
- [x] Replace bucket-only tests with realistic chart-card regressions; watch the long-gap/same-bucket cases fail on current code.
- [x] Segment usable metric timestamps before bucketing; keep each bucket's plotted time within its sample envelope and its metadata/transform semantics.
- [x] Run focused ChartSegmenterTests and LiveHistoryTimezoneTests, then the full signed suite. Expected: TEST SUCCEEDED, only existing opt-in skips.
- [ ] Commit, independent final review, resolve important findings with RED→GREEN evidence, push main and run tools/ship.sh testflight under existing release authorization. Verify external availability and record evidence.


## Verification and independent review

The original implementation failed 16 assertions in 12 realistic chart-card tests. The initial fix passed 26 focused chart/timezone tests and the signed full suite (1,955 tests, two existing opt-in skips).

Independent review approved the timestamp segmentation, separate bucket averages, identity, date bounds and matching line/area series. It found one important regression: splitting a coarse bucket into three isolated EDR readings exposes a smoothing path that dropped the estimated-source flag. The new displayed-points regression failed before the correction and passed afterward; smoothing now preserves the center point's estimated flag and never blends separate runs. Final signed suite: **1,956 tests, two existing opt-in skips, zero failures**. No deferred findings or declined-to-judge items.

Evidence: `/private/tmp/wythin-chart-gaps-red.log`, `/private/tmp/wythin-chart-gaps-focused.log`, `/private/tmp/wythin-chart-gaps-review-red.log`, `/private/tmp/wythin-chart-gaps-full.log`. This presentation-only correction does not establish that physical overnight recording failures are resolved.
