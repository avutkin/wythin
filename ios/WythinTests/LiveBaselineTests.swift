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
