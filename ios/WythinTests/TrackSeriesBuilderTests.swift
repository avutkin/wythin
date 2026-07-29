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
                    sampleCount: 200, wearSeconds: wearSeconds)
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
        XCTAssertEqual(bars.last!.dayCount, 5)
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

    // MARK: summary

    func testSummaryCountsInTheBenefitDirection() {
        let today = date(2026, 7, 28)
        let days  = week(0, today: today).days
        // Baseline needs ≥14 days; give 20 at pip 60, then this week's 7 at 50.
        var rollups = (8...27).map {
            rollup(cal.date(byAdding: .day, value: -$0, to: today)!, pip: 60)
        }
        rollups += days.map { rollup($0, pip: 50) }   // lower = better
        let s = TrackSeriesBuilder.series(spec: spec("Inner Noise"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.presentCount, 7)
        XCTAssertEqual(s.betterCount, 7)
        XCTAssertEqual(s.summary, "7 of 7 days better than your baseline.")
    }

    func testSummarySaysTypicalWhenTheBaselineIsNotPersonal() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.prefix(3).map { rollup($0, dc: 100) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: Array(rollups), asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "3 of 3 days better than typical.")
    }

    func testSummaryIsSingularForOneDay() {
        let today = date(2026, 7, 28)
        let rollups = [rollup(date(2026, 7, 27), dc: 100)]
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "1 of 1 day better than typical.")
    }

    func testSummaryForNoData() {
        let today = date(2026, 7, 28)
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"),
                                          range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: [], asOf: today, calendar: cal)
        XCTAssertEqual(s.summary, "No data this period.")
        XCTAssertNil(s.average)
        XCTAssertTrue(s.overlay.isEmpty)
    }

    // MARK: weekly overlay

    func testMonthSeriesHasWeeklyOverlaySegments() {
        let today = date(2026, 7, 28)
        let r = TrackRangeBuilder.range(period: .month, offset: 0, today: today, calendar: cal)
        let rollups = r.days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: r,
                                          priorRange: TrackRangeBuilder.range(period: .month, offset: 1,
                                                                              today: today, calendar: cal),
                                          rollups: rollups, asOf: today, calendar: cal)
        // July 2026 spans 5 partial ISO weeks.
        XCTAssertEqual(s.overlay.count, 5)
        XCTAssertEqual(s.overlay.first!.value, 8, accuracy: 0.001)
    }

    /// The weekly overlay is a month-view device only. Both non-month periods
    /// are built here: with only the week case covered, a gate written
    /// `!= .week` instead of `== .month` would pass while shipping ~26 stray
    /// weekly rules across the 6M chart.
    func testWeekAndSixMonthSeriesHaveNoOverlay() {
        let today = date(2026, 7, 28)
        let rollups = week(0, today: today).days.map { rollup($0, dc: 8) }
        let w = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: week(0, today: today),
                                          priorRange: week(1, today: today),
                                          rollups: rollups, asOf: today, calendar: cal)
        XCTAssertTrue(w.overlay.isEmpty)

        let six      = TrackRangeBuilder.range(period: .sixMonth, offset: 0,
                                               today: today, calendar: cal)
        let sixPrior = TrackRangeBuilder.range(period: .sixMonth, offset: 1,
                                               today: today, calendar: cal)
        let sixRollups = six.days.map { rollup($0, dc: 8) }
        let s = TrackSeriesBuilder.series(spec: spec("Vagal Tone"), range: six,
                                          priorRange: sixPrior,
                                          rollups: sixRollups, asOf: today, calendar: cal)
        // Data is genuinely present, so an empty overlay is the gate at work
        // rather than there being nothing to group.
        XCTAssertEqual(s.bars.count, 6)
        XCTAssertNotNil(s.bars.first!.value)
        XCTAssertTrue(s.overlay.isEmpty)
    }
}
