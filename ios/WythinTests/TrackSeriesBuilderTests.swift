import XCTest
@testable import Wythin

final class TrackSeriesBuilderTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!)
    }

    private func spec(_ label: String) -> TrackMetricSpec {
        TrackMetrics.all.first { $0.def.label == label }!
    }

    /// A rollup with `dc`, `pip` and `dfa1` set; other fields nil.
    private func rollup(_ day: Date, dc: Double? = nil, pip: Double? = nil,
                        dfa1: Double? = nil,
                        wearSeconds: Double = 400) -> DailyRollup {
        DailyRollup(day: day, dc: dc, rmssd: nil, rsaMs: nil, rcmse: nil,
                    pip: pip, dfa1: dfa1, stressBalance: nil, vti: nil, meanBPM: nil,
                    sampleCount: 200, wearSeconds: wearSeconds, mean: [:], sd: [:])
    }

    private func week(_ offset: Int, today: Date) -> TrackRange {
        TrackRangeBuilder.range(period: .week, offset: offset, today: today, calendar: cal)
    }

    // MARK: bars

    func testOneBarPerBucketWithMissingDaysNil() {
        let today = date(2026, 7, 28)                      // Tuesday
        let r = week(0, today: today)                      // Mon 27 Jul – Sun 2 Aug
        let rollups = [rollup(date(2026, 7, 27), dc: 6),
                       rollup(date(2026, 7, 29), dc: 10)]
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)

        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars[0].value, 6)
        XCTAssertNil(bars[1].value)                        // Tue has no rollup
        XCTAssertEqual(bars[2].value, 10)
        XCTAssertNil(bars[6].value)
    }

    func testMonthlyBucketIsTheUnweightedMeanOfDailyMeans() {
        let today = date(2026, 7, 15)
        let r = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: today, calendar: cal)
        // July: two days, one with 10× the wear time. The mean must be 8, not
        // pulled toward the long day.
        let rollups = [rollup(date(2026, 7, 1), dc: 6, wearSeconds: 40_000),
                       rollup(date(2026, 7, 2), dc: 10, wearSeconds: 4_000),
                       rollup(date(2026, 7, 3), dc: 6),
                       rollup(date(2026, 7, 4), dc: 10),
                       rollup(date(2026, 7, 5), dc: 8)]
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
        XCTAssertEqual(bars.last!.value!, 8.0, accuracy: 0.001)
        // `TrackBar.dayCount` was removed as dead weight (never read outside
        // this assertion — a test assertion is not a consumer, and unlike
        // `DailyRollup`'s cheap-to-keep fields it was trivially
        // recomputable from cached rollups whenever actually needed).
    }

    func testMonthWithTooFewValidDaysIsSuppressed() {
        let today = date(2026, 7, 15)
        let r = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: today, calendar: cal)
        let rollups = (1...4).map { rollup(date(2026, 7, $0), dc: 8) }   // 4 < 5
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
        XCTAssertNil(bars.last!.value)
    }

    // MARK: baseline

    func testBaselineIsTheMedianOfTheLast90Days() {
        let asOf = date(2026, 7, 28)
        // 20 days: values 1…20 → median 10.5
        let rollups = (1...20).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: Double($0))
        }
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"), rollups: rollups,
                                            asOf: asOf, calendar: cal)
        XCTAssertEqual(b.value, 10.5, accuracy: 0.001)
        XCTAssertTrue(b.isPersonal)
    }

    func testBaselineFallsBackBelowFourteenDays() {
        let asOf = date(2026, 7, 28)
        let rollups = (1...13).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 99)
        }
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"), rollups: rollups,
                                            asOf: asOf, calendar: cal)
        XCTAssertEqual(b.value, spec("Vagal Tone").fallbackReference)
        XCTAssertFalse(b.isPersonal)
    }

    func testBaselineIgnoresDaysOlderThanTheWindow() {
        let asOf = date(2026, 7, 28)
        let recent = (1...20).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 10)
        }
        let ancient = (100...130).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 1000)
        }
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"), rollups: recent + ancient,
                                            asOf: asOf, calendar: cal)
        XCTAssertEqual(b.value, 10, accuracy: 0.001)
    }

    /// Pins the `>` vs `>=` boundary of `cutoff = asOf - baselineWindowDays`
    /// directly, rather than with data far outside the window. 13 days
    /// safely inside the window are one short of `minBaselineDays` on their
    /// own, so whether a 14th candidate day tips the baseline into
    /// "personal" reveals exactly which side of `day > cutoff` it falls on.
    func testBaselineExcludesTheDayExactlyAtTheCutoff() {
        let asOf = date(2026, 7, 28)
        let withinWindow = (1...13).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 10)
        }
        // Exactly 90 days back: the cutoff itself. `day > cutoff` must
        // exclude it, leaving only 13 days — below minBaselineDays.
        let atCutoff = rollup(cal.date(byAdding: .day, value: -90, to: asOf)!, dc: 10)
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"),
                                            rollups: withinWindow + [atCutoff],
                                            asOf: asOf, calendar: cal)
        XCTAssertFalse(b.isPersonal)
        XCTAssertEqual(b.value, spec("Vagal Tone").fallbackReference)
    }

    func testBaselineIncludesTheDayJustInsideTheCutoff() {
        let asOf = date(2026, 7, 28)
        let withinWindow = (1...13).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: asOf)!, dc: 10)
        }
        // 89 days back: one day more recent than the cutoff, the oldest day
        // the window actually admits. Its inclusion is what takes the count
        // from 13 to the 14 minBaselineDays requires.
        let justInside = rollup(cal.date(byAdding: .day, value: -89, to: asOf)!, dc: 10)
        let b = TrackSeriesBuilder.baseline(spec: spec("Vagal Tone"),
                                            rollups: withinWindow + [justInside],
                                            asOf: asOf, calendar: cal)
        XCTAssertTrue(b.isPersonal)
        XCTAssertEqual(b.value, 10, accuracy: 0.001)
    }

    // MARK: delta

    func testDeltaIsBenefitSignedForHigherIsBetter() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 11) }
                    + week(1, today: today).days.map { rollup($0, dc: 10) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 10, accuracy: 0.001)
    }

    func testDeltaIsBenefitSignedForLowerIsBetter() {
        let today = date(2026, 7, 28)
        // Inner Noise fell 60 → 54. A fall is an improvement: +10%.
        let rollups = week(0, today: today).days.map { rollup($0, pip: 54) }
                    + week(1, today: today).days.map { rollup($0, pip: 60) }
        let s = TrackSeriesBuilder.series(spec: spec("Inner Noise"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 10, accuracy: 0.001)
    }

    func testDeltaIsNilWhenThePriorPeriodIsEmpty() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 11) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertNil(s.deltaPct)
        XCTAssertNotNil(s.average)
    }

    // MARK: delta — .target(1.0)

    /// Harmony is the only `.target` metric, and the only one where "better"
    /// is neither up nor down. Moving *toward* 1.0 must read as positive
    /// whichever side it starts on.
    func testDeltaIsBenefitSignedForTargetDirection() {
        let today = date(2026, 7, 28)
        // benefit(x) = -|x - 1|. Prior 0.8 → -0.2, current 0.9 → -0.1.
        // (-0.1 - -0.2) / 0.2 = +50%.
        let rollups = week(0, today: today).days.map { rollup($0, dfa1: 0.9) }
                    + week(1, today: today).days.map { rollup($0, dfa1: 0.8) }
        let s = TrackSeriesBuilder.series(spec: spec("Harmony"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 50, accuracy: 0.001)
    }

    /// Approaching 1.0 from above is an improvement too — a plain "higher is
    /// better" or "lower is better" rule would get one of these two backwards.
    func testDeltaIsPositiveApproachingTheTargetFromAbove() {
        let today = date(2026, 7, 28)
        // Prior 1.4 → -0.4, current 1.2 → -0.2. (-0.2 - -0.4) / 0.4 = +50%.
        let rollups = week(0, today: today).days.map { rollup($0, dfa1: 1.2) }
                    + week(1, today: today).days.map { rollup($0, dfa1: 1.4) }
        let s = TrackSeriesBuilder.series(spec: spec("Harmony"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 50, accuracy: 0.001)
        XCTAssertEqual(s.average!, 1.2, accuracy: 0.001)
    }

    /// Equally far from 1.0 on the other side is no change at all, even though
    /// the raw value moved by 0.4.
    func testDeltaIsZeroWhenTheDistanceToTargetIsUnchanged() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dfa1: 1.2) }
                    + week(1, today: today).days.map { rollup($0, dfa1: 0.8) }
        let s = TrackSeriesBuilder.series(spec: spec("Harmony"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, 0, accuracy: 0.001)
    }

    /// The ill-conditioned case `benefitDelta` guards: a prior average sitting
    /// exactly on the target has benefit 0, so the percentage would divide by
    /// zero. No chip is better than an infinite one.
    func testDeltaIsNilWhenThePriorAverageIsExactlyOnTarget() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dfa1: 1.3) }
                    + week(1, today: today).days.map { rollup($0, dfa1: 1.0) }
        let s = TrackSeriesBuilder.series(spec: spec("Harmony"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertNil(s.deltaPct)
        XCTAssertNotNil(s.average)
    }

    /// Near the target a small absolute move blows the percentage up; the
    /// ±100 clamp is what keeps the chip from reading "▼ 900%".
    func testDeltaIsClampedNearTheTarget() {
        let today = date(2026, 7, 28)
        // Prior 0.99 → -0.01, current 0.89 → -0.11. Raw: -1000%.
        let rollups = week(0, today: today).days.map { rollup($0, dfa1: 0.89) }
                    + week(1, today: today).days.map { rollup($0, dfa1: 0.99) }
        let s = TrackSeriesBuilder.series(spec: spec("Harmony"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.deltaPct!, -100, accuracy: 0.001)
    }

    // MARK: reference line — previous period's average

    /// The line drawn on the chart is this period's *prior* page's average —
    /// not the 90-day personal baseline (`series.reference`, which still
    /// feeds only the server payload; see its doc in `TrackSeriesBuilder`).
    func testReferenceLineIsThePriorPeriodAverage() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 11) }
                    + week(1, today: today).days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.referenceLines.count, 1)
        XCTAssertEqual(s.referenceLines.first!.value, 8, accuracy: 0.001)
        XCTAssertEqual(s.referenceLines.first!.label, "prior week avg")
    }

    /// The prior-period average must come from *only* the prior page's own
    /// days. Blending in even one of the current period's days would move
    /// this off 10 — the two periods' values (10 vs 1000) are deliberately
    /// far apart so any such leak is impossible to miss.
    func testReferenceLineExcludesTheCurrentPeriodsOwnDays() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 1000) }
                    + week(1, today: today).days.map { rollup($0, dc: 10) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.referenceLines.first!.value, 10, accuracy: 0.001)
    }

    /// A partially-populated prior week still contributes a line — averaged
    /// over just the days it actually has, the same rule `average` itself
    /// follows for the current period.
    func testReferenceLineAveragesOnlyThePriorPeriodsPresentDays() {
        let today = date(2026, 7, 28)
        let priorDays = week(1, today: today).days
        var rollups = week(0, today: today).days.map { rollup($0, dc: 5) }
        rollups += [rollup(priorDays[0], dc: 4), rollup(priorDays[1], dc: 8)]   // only 2 of 7
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.referenceLines.first!.value, 6, accuracy: 0.001)   // (4 + 8) / 2
    }

    /// No prior period at all (the first page a person ever opens) draws no
    /// line, rather than falling back to some other value the legend
    /// wouldn't actually describe correctly.
    func testReferenceLineIsEmptyWhenThePriorPeriodHasNoData() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertTrue(s.referenceLines.isEmpty)
    }

    /// The legend label follows whichever period is on screen, not just week.
    func testReferenceLineLabelMatchesThePeriod() {
        let today = date(2026, 7, 28)
        let m = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let mPrior = TrackRangeBuilder.range(period: .month, offset: 1, today: today, calendar: cal)
        let rollups = m.days.map { rollup($0, dc: 8) } + mPrior.days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: m, priorRange: mPrior,
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.referenceLines.first!.label, "prior month avg")

        let six = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: today, calendar: cal)
        let sixPrior = TrackRangeBuilder.range(period: .sixMonth, offset: 1, today: today, calendar: cal)
        let sixRollups = six.days.map { rollup($0, dc: 8) } + sixPrior.days.map { rollup($0, dc: 8) }
        let sixSeries = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: six, priorRange: sixPrior,
                                                  rollups: sixRollups, asOf: today, calendar: cal)
        XCTAssertEqual(sixSeries.referenceLines.first!.label, "prior 6 months avg")
    }

    // MARK: summary

    /// Counted in the benefit direction against the *reference line*
    /// (prior week's average), not the 90-day baseline `betterCount` still
    /// tracks for the server payload — this is Inner Noise, where lower is
    /// better, so a fall from 60 to 50 reads as an improvement.
    func testSummaryCountsBetterThanThePriorPeriod() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, pip: 50) }
                    + week(1, today: today).days.map { rollup($0, pip: 60) }
        let s = TrackSeriesBuilder.series(spec: spec("Inner Noise"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.presentCount, 7)
        XCTAssertEqual(s.summary, "7 of 7 days better than prior week.")
    }

    func testSummaryIsSingularForOneDay() {
        let today = date(2026, 7, 28)
        let rollups = [rollup(date(2026, 7, 27), dc: 100)]
                    + week(1, today: today).days.map { rollup($0, dc: 50) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "1 of 1 day better than prior week.")
    }

    func testSummaryForNoData() {
        let today = date(2026, 7, 28)
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: [], asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "No data this period.")
        XCTAssertNil(s.average)
    }

    /// Distinct from "No data this period.": there *is* current-period data,
    /// just nothing to compare it against yet. Conflating the two would tell
    /// someone with a full week of real readings that nothing was recorded.
    func testSummarySaysNoPriorPeriodWhenThereIsCurrentDataButNoPriorPeriod() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "No prior week to compare yet.")
    }

    // MARK: month bucketing — daily bars, weekly average lines

    /// The month page's bars are days, one per day of the month — July 2026
    /// has 31, not the 5 calendar weeks it spans. The weekly grouping still
    /// exists, but as the average *lines* drawn over these bars
    /// (`weekAverages`), not as the bars themselves.
    func testMonthPeriodProducesDailyBars() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
        XCTAssertEqual(bars.count, 31)
        XCTAssertEqual(bars.map(\.bucket.start), r.buckets.map(\.start))
        XCTAssertEqual(bars.first!.value!, 8, accuracy: 0.001)
    }

    /// A single day's bar is that day alone — not smeared with its
    /// neighbours', which is what a surviving weekly collapse would produce.
    func testEachMonthlyBarIsItsOwnDayOnly() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = [rollup(date(2026, 7, 6), dc: 6), rollup(date(2026, 7, 9), dc: 14)]
        let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
        XCTAssertEqual(bars.first { $0.bucket.start == date(2026, 7, 6) }?.value, 6)
        XCTAssertEqual(bars.first { $0.bucket.start == date(2026, 7, 9) }?.value, 14)
        XCTAssertNil(bars.first { $0.bucket.start == date(2026, 7, 7) }?.value)
    }

    /// Every day of July lands under exactly one average line, the lines are
    /// contiguous, and together they span the whole month — so no bar is left
    /// without a line over it and no line reaches past the month's edges.
    func testWeekAveragesAreContiguousAndCoverTheWholeMonth() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let weeks = TrackSeriesBuilder.weekAverages(
            dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
            calendar: cal)
        XCTAssertEqual(weeks.count, 5)
        XCTAssertEqual(weeks.first!.start, r.start)
        XCTAssertEqual(weeks.last!.end, r.end)
        for (a, b) in zip(weeks, weeks.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
    }

    /// Only the two *edge* weeks may be partial — every week fully inside the
    /// month must be a full 7 days. A bug that clipped every span to some
    /// fixed size (rather than only where the month boundary actually cuts
    /// across a calendar week) would fail this on the interior weeks.
    func testOnlyTheMonthsEdgeWeeksArePartial() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let weeks = TrackSeriesBuilder.weekAverages(
            dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
            calendar: cal)
        let spans = weeks.map { cal.dateComponents([.day], from: $0.start, to: $0.end).day! }
        for span in spans.dropFirst().dropLast() {
            XCTAssertEqual(span, 7, "an interior week must be a full 7 days")
        }
        XCTAssertLessThan(spans.first!, 7, "July 2026 starts mid-week (Wednesday), so the first span is partial")
        XCTAssertLessThan(spans.last!, 7, "July 2026 ends mid-week (Friday), so the last span is partial")
    }

    /// The axis label replaces seven day labels, so it names the period the
    /// week covers rather than just where it starts — including on the two
    /// edge weeks, which are exactly the ones that don't run a full seven
    /// days. Days only: the page header already names the month, and five
    /// month-prefixed labels don't fit across a phone.
    func testWeekAverageLabelNamesTheWeekPeriod() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let weeks = TrackSeriesBuilder.weekAverages(
            dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
            calendar: cal)
        XCTAssertEqual(weeks.map(\.label), ["1–5", "6–12", "13–19", "20–26", "27–31"])
    }

    /// The label hangs off `midDay`, which must be a day the week actually
    /// contains — otherwise the axis anchors it against a date outside the
    /// span it describes (or, on a partial edge week, outside the month).
    func testWeekAverageMidDayFallsInsideItsOwnWeek() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let weeks = TrackSeriesBuilder.weekAverages(
            dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
            calendar: cal)
        for week in weeks {
            XCTAssertTrue(week.midDay >= week.start && week.midDay < week.end,
                          "\(week.label) anchors its label on \(week.midDay)")
        }
    }

    /// An average line covers only the days that actually have a rollup,
    /// ignoring the nil ones rather than treating them as zero.
    func testWeekAverageCoversOnlyPresentDaysInASparseWeek() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        // July 2026's second calendar week is Jul 6 (Mon) – Jul 12 (Sun).
        // Only Jul 7 (dc=6) and Jul 9 (dc=14) get a rollup; the rest of that
        // week has none. Every other week in the month is fully populated.
        let sparseWeekStart = date(2026, 7, 6)
        let sparseWeekEnd   = date(2026, 7, 12)
        let rollups = r.days.compactMap { day -> DailyRollup? in
            guard (sparseWeekStart...sparseWeekEnd).contains(day) else { return rollup(day, dc: 8) }
            if day == date(2026, 7, 7) { return rollup(day, dc: 6) }
            if day == date(2026, 7, 9) { return rollup(day, dc: 14) }
            return nil
        }
        let weeks = TrackSeriesBuilder.weekAverages(
            dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
            calendar: cal)
        let sparse = try! XCTUnwrap(weeks.first { $0.start == sparseWeekStart })
        XCTAssertEqual(sparse.value!, 10, accuracy: 0.001)   // (6 + 14) / 2, ignoring the 5 nil days
        // The line still spans the whole week, not just the two days behind
        // its value — it is the week's average, drawn over the week.
        XCTAssertEqual(sparse.end, cal.date(byAdding: .day, value: 1, to: sparseWeekEnd))
    }

    /// A calendar week with no data in it at all still produces an entry — a
    /// nil-valued one, which draws no line but keeps its axis slot — rather
    /// than vanishing and shifting every later week's label onto the wrong days.
    func testWeekAverageIsNilForAWeekWithNoDataAtAll() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        // July 2026's third calendar week, Jul 13 (Mon) – Jul 19 (Sun), has
        // no rollups whatsoever; every other week is fully populated.
        let emptyWeek = date(2026, 7, 13)...date(2026, 7, 19)
        let rollups = r.days.compactMap { day -> DailyRollup? in
            emptyWeek.contains(day) ? nil : rollup(day, dc: 8)
        }
        let weeks = TrackSeriesBuilder.weekAverages(
            dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
            calendar: cal)
        XCTAssertEqual(weeks.count, 5, "the empty week keeps its slot, it is not dropped")
        let empty = try! XCTUnwrap(weeks.first { $0.start == date(2026, 7, 13) })
        XCTAssertNil(empty.value)
        XCTAssertNotNil(weeks.first { $0.start == date(2026, 7, 6) }?.value)    // week before
        XCTAssertNotNil(weeks.first { $0.start == date(2026, 7, 20) }?.value)   // week after
    }

    /// Every period's bars now come straight out of `range.buckets` — the
    /// month-only regrouping that used to sit in `bars()` is gone, and no
    /// period may quietly reintroduce one.
    func testEveryPeriodsBarsComeStraightFromItsRangeBuckets() {
        let today = date(2026, 7, 28)
        for period in TrackPeriod.allCases {
            let r = TrackRangeBuilder.range(period: period, offset: 0, today: today, calendar: cal)
            let rollups = r.days.map { rollup($0, dc: 8) }
            let bars = TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups)
            XCTAssertEqual(bars.map(\.bucket.start), r.buckets.map(\.start), "\(period.rawValue)")
        }
    }

    /// Enumerates a full year of month pages against every weekday the 1st
    /// could fall on (by varying `today`'s month across 2026) and checks the
    /// line count stays in 4…6 — few enough that their axis labels, each a
    /// full "6–12" period rather than a bare number, fit across a phone
    /// without any thinning pass.
    func testMonthNeverProducesMoreThanSixWeekAverages() {
        for month in 1...12 {
            let today = date(2026, month, 15)
            let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
            let rollups = r.days.map { rollup($0, dc: 8) }
            let weeks = TrackSeriesBuilder.weekAverages(
                dailyBars: TrackSeriesBuilder.bars(spec: spec("Vagal Tone"), range: r, rollups: rollups),
                calendar: cal)
            XCTAssertLessThanOrEqual(weeks.count, 6, "month \(month) produced \(weeks.count) week lines")
            XCTAssertGreaterThanOrEqual(weeks.count, 4, "month \(month) produced \(weeks.count) week lines")
        }
    }

    /// Only the month page carries average lines. The week page is seven days
    /// wide — one line there would just redraw the header average — and 6M's
    /// bars are whole months, which weeks do not divide.
    func testOnlyTheMonthSeriesCarriesWeekAverages() {
        let today = date(2026, 7, 28)
        for period in TrackPeriod.allCases {
            let r = TrackRangeBuilder.range(period: period, offset: 0, today: today, calendar: cal)
            let prior = TrackRangeBuilder.range(period: period, offset: 1, today: today, calendar: cal)
            let rollups = (r.days + prior.days).map { rollup($0, dc: 8) }
            let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: r, priorRange: prior,
                                              rollups: rollups, asOf: today, calendar: cal)
            if period == .month {
                XCTAssertEqual(s.weekAverages.count, 5)
            } else {
                XCTAssertTrue(s.weekAverages.isEmpty, "\(period.rawValue) must not draw week lines")
            }
        }
    }
}
