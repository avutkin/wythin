import XCTest
@testable import Wythin

final class LiveBaselineTests: XCTestCase {

    private func rollup(daysAgo: Int, hrMean: Double, hrSD: Double) -> DailyRollup {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo,
                                        to: Calendar.current.startOfDay(for: Date()))!
        return DailyRollup(day: day, dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                           pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                           meanBPM: hrMean, sampleCount: 1000, wearSeconds: 2000,
                           mean: [LiveMetric.hr.rawValue: hrMean],
                           sd:   [LiveMetric.hr.rawValue: hrSD])
    }

    func testNilWithNoRollups() {
        XCTAssertNil(LiveBaseline.build(rollups: []))
    }

    func testCentreIsTheMeanOfDailyMeans() {
        let b = LiveBaseline.build(rollups: [
            rollup(daysAgo: 1, hrMean: 60, hrSD: 8),
            rollup(daysAgo: 2, hrMean: 70, hrSD: 8)
        ])
        XCTAssertEqual(b?.stat(for: .hr)?.mean ?? 0, 65, accuracy: 0.01)
    }

    /// The load-bearing property: spread is pooled WITHIN-day variance, not the
    /// spread of the two daily means (which would be ~7).
    func testSpreadIsPooledWithinDayNotBetweenDay() {
        let b = LiveBaseline.build(rollups: [
            rollup(daysAgo: 1, hrMean: 60, hrSD: 8),
            rollup(daysAgo: 2, hrMean: 70, hrSD: 8)
        ])
        XCTAssertEqual(b?.stat(for: .hr)?.sd ?? 0, 8, accuracy: 0.01)
    }

    /// Distinguishes pooled variance from a weighted MEAN OF SDs. The two
    /// formulas coincide whenever weights or SDs are equal (as in the two
    /// tests above), so only unequal weights AND unequal SDs together can
    /// catch a regression to the wrong one.
    ///
    ///   weighted mean of SD (wrong): (4000·3 + 1000·9) / 5000        = 4.2
    ///   pooled variance     (right): sqrt((4000·3² + 1000·9²) / 5000)
    ///                               = sqrt((36000 + 81000) / 5000)
    ///                               = sqrt(23.4) ≈ 4.8374
    func testSpreadIsPooledVarianceNotWeightedMeanOfSD() {
        let long  = DailyRollup(day: Date(), dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                                pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                                meanBPM: 60, sampleCount: 4_000, wearSeconds: 8_000,
                                mean: [LiveMetric.hr.rawValue: 60],
                                sd:   [LiveMetric.hr.rawValue: 3])
        let short = DailyRollup(day: Date().addingTimeInterval(-86_400), dc: nil, rmssd: nil,
                                rsaMs: nil, rcmse: nil, pip: nil, dfa1: nil, stressBalance: nil,
                                vti: nil, meanBPM: 60, sampleCount: 1_000, wearSeconds: 2_000,
                                mean: [LiveMetric.hr.rawValue: 60],
                                sd:   [LiveMetric.hr.rawValue: 9])
        let sd = LiveBaseline.build(rollups: [long, short])?.stat(for: .hr)?.sd ?? 0
        XCTAssertEqual(sd, 4.8374, accuracy: 0.001)
    }

    /// A day with a `mean` but no matching `sd` must not count toward the
    /// centre or `n` — only toward the spread would leave `n` overstating how
    /// much evidence backs it. `DailyRollupCompute.rollup()` always writes
    /// both together today, so this is unreachable in practice, but nothing in
    /// `DailyRollup`'s type enforces that pairing.
    func testDayMissingSDIsExcludedFromCentreAndN() {
        let complete = rollup(daysAgo: 1, hrMean: 60, hrSD: 8)
        let missingSDDay = Calendar.current.date(byAdding: .day, value: -2,
            to: Calendar.current.startOfDay(for: Date()))!
        let incomplete = DailyRollup(day: missingSDDay, dc: nil, rmssd: nil, rsaMs: nil,
                                     rcmse: nil, pip: nil, dfa1: nil, stressBalance: nil,
                                     vti: nil, meanBPM: 100, sampleCount: 1000, wearSeconds: 2000,
                                     mean: [LiveMetric.hr.rawValue: 100],
                                     sd: [:])
        let b = LiveBaseline.build(rollups: [complete, incomplete])
        XCTAssertEqual(b?.stat(for: .hr)?.n, 1)
        XCTAssertEqual(b?.stat(for: .hr)?.mean ?? 0, 60, accuracy: 0.01)
    }

    func testPooledSpreadWeightsByDayLength() {
        // A day with 10x the samples should dominate the pooled spread.
        let long  = DailyRollup(day: Date(), dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                                pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                                meanBPM: 60, sampleCount: 10_000, wearSeconds: 20_000,
                                mean: [LiveMetric.hr.rawValue: 60],
                                sd:   [LiveMetric.hr.rawValue: 10])
        let short = DailyRollup(day: Date().addingTimeInterval(-86_400), dc: nil, rmssd: nil,
                                rsaMs: nil, rcmse: nil, pip: nil, dfa1: nil, stressBalance: nil,
                                vti: nil, meanBPM: 60, sampleCount: 1_000, wearSeconds: 2_000,
                                mean: [LiveMetric.hr.rawValue: 60],
                                sd:   [LiveMetric.hr.rawValue: 2])
        let sd = LiveBaseline.build(rollups: [long, short])?.stat(for: .hr)?.sd ?? 0
        XCTAssertGreaterThan(sd, 8, "the long day must dominate")
    }

    /// The day's total tick count is the wrong weight: a metric that computed
    /// twice all day sat in the pool at the full weight of a 40,000-tick day.
    /// Pooling must weight each day by how many samples of THAT metric it
    /// actually had.
    ///
    ///   by the day's total (wrong): sqrt((40000·9² + 1000·3²) / 41000) ≈ 8.902
    ///   by the metric's own (right): sqrt((2·9²    + 1000·3²) / 1002)  ≈ 3.024
    func testPooledSpreadWeightsByTheMetricsOwnCount() {
        let key = LiveMetric.rcmse.rawValue
        let sparse = DailyRollup(day: Date(), dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                                 pip: nil, dfa1: nil, stressBalance: nil, vti: nil,
                                 meanBPM: nil, sampleCount: 40_000, wearSeconds: 80_000,
                                 mean: [key: 1.4], sd: [key: 9], count: [key: 2])
        let dense = DailyRollup(day: Date().addingTimeInterval(-86_400), dc: nil, rmssd: nil,
                                rsaMs: nil, rcmse: nil, pip: nil, dfa1: nil, stressBalance: nil,
                                vti: nil, meanBPM: nil, sampleCount: 1_000, wearSeconds: 2_000,
                                mean: [key: 1.4], sd: [key: 3], count: [key: 1_000])
        let sd = LiveBaseline.build(rollups: [sparse, dense])?.stat(for: .rcmse)?.sd ?? 0
        XCTAssertEqual(sd, 3.0239, accuracy: 0.001)
    }

    func testProvisionalUntilFirmDays() {
        let few = (1...3).map { rollup(daysAgo: $0, hrMean: 60, hrSD: 8) }
        XCTAssertTrue(LiveBaseline.build(rollups: few)?.provisional ?? false)

        let many = (1...LivePrior.firmDays).map { rollup(daysAgo: $0, hrMean: 60, hrSD: 8) }
        XCTAssertFalse(LiveBaseline.build(rollups: many)?.provisional ?? true)
    }

    func testZUsesThePriorBlendSoOneDayCannotProduceAMonsterScore() {
        let one = LiveBaseline.build(rollups: [rollup(daysAgo: 1, hrMean: 60, hrSD: 0.1)])
        let z = one?.z(70, for: .hr)
        XCTAssertNotNil(z)
        XCTAssertLessThan(abs(z!), 5, "a degenerate one-day SD must not yield z=100")
    }

    func testMetricWithNoDataHasNoStat() {
        let b = LiveBaseline.build(rollups: [rollup(daysAgo: 1, hrMean: 60, hrSD: 8)])
        XCTAssertNil(b?.stat(for: .dfa1))
        XCTAssertNil(b?.z(1.0, for: .dfa1))
    }

    func testOnlyRollupsInsideTheWindowCount() {
        let old = rollup(daysAgo: AnchorBaseline.windowDays + 5, hrMean: 200, hrSD: 8)
        let recent = rollup(daysAgo: 1, hrMean: 60, hrSD: 8)
        let b = LiveBaseline.build(rollups: [old, recent])
        XCTAssertEqual(b?.dayCount, 1)
        XCTAssertEqual(b?.stat(for: .hr)?.mean ?? 0, 60, accuracy: 0.01)
    }
}
