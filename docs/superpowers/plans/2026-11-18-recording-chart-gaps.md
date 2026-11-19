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
- [ ] Replace bucket-only tests with realistic chart-card regressions; watch the long-gap/same-bucket cases fail on current code.
- [ ] Segment usable metric timestamps before bucketing; keep each bucket's plotted time within its sample envelope and its metadata/transform semantics.
- [ ] Run focused ChartSegmenterTests and LiveHistoryTimezoneTests, then the full signed suite. Expected: TEST SUCCEEDED, only existing opt-in skips.
- [ ] Commit, independent final review, resolve important findings with RED→GREEN evidence, push main and run tools/ship.sh testflight under existing release authorization. Verify external availability and record evidence.
