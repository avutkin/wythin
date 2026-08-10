import XCTest
@testable import Wythin

final class LiveDayComparisonTests: XCTestCase {

    private let today = Calendar.current.startOfDay(for: Date())

    private func day(_ daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!
    }

    private func rollup(daysAgo: Int, wearSeconds: Double = 4 * 3600,
                        hrMean: Double = 60, hrSD: Double = 8,
                        dfa1Mean: Double? = nil, dfa1SD: Double? = nil) -> DailyRollup {
        var mean: [String: Double] = [LiveMetric.hr.rawValue: hrMean]
        var sd:   [String: Double] = [LiveMetric.hr.rawValue: hrSD]
        if let m = dfa1Mean, let s = dfa1SD {
            mean[LiveMetric.dfa1.rawValue] = m
            sd[LiveMetric.dfa1.rawValue]   = s
        }
        return DailyRollup(day: day(daysAgo), dc: nil, rmssd: nil, rsaMs: nil, rcmse: nil,
                           pip: nil, dfa1: dfa1Mean, stressBalance: nil, vti: nil,
                           meanBPM: hrMean, sampleCount: 1000, wearSeconds: wearSeconds,
                           mean: mean, sd: sd)
    }

    // MARK: - Day selection

    /// The reference is the last 7 *recorded* days: short-wear days are
    /// skipped and the window silently reaches further back instead.
    func testSkipsShortWearDaysAndExtendsBack() {
        var rollups = (1...5).map { rollup(daysAgo: $0) }                      // 5 good recent
        rollups += (6...9).map { rollup(daysAgo: $0, wearSeconds: 600) }       // 4 too short
        rollups += (10...12).map { rollup(daysAgo: $0) }                       // 3 good older
        let days = LiveDayComparison.referenceDays(rollups: rollups, before: today)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.day), [1, 2, 3, 4, 5, 10, 11].map(day))
    }

    func testExcludesTheViewedDayAndLater() {
        let rollups = (0...8).map { rollup(daysAgo: $0) }
        let days = LiveDayComparison.referenceDays(rollups: rollups, before: today)
        XCTAssertFalse(days.contains { $0.day >= today })
        XCTAssertEqual(days.first?.day, day(1))
    }

    /// Exactly 30 minutes qualifies — the gate is ≥, not >.
    func testThirtyMinutesQualifies() {
        let days = LiveDayComparison.referenceDays(
            rollups: [rollup(daysAgo: 1, wearSeconds: 1800)], before: today)
        XCTAssertEqual(days.count, 1)
    }

    func testNoReferenceBelowTwoQualifyingDays() {
        XCTAssertNil(LiveDayComparison.reference(
            rollups: [rollup(daysAgo: 1)], before: today))
        XCTAssertNotNil(LiveDayComparison.reference(
            rollups: [rollup(daysAgo: 1), rollup(daysAgo: 2)], before: today))
    }

    /// A qualifying day head-count is not per-metric evidence: days that never
    /// computed a metric contribute nothing to its stat.
    func testMetricStatOnlyCountsDaysCarryingTheMetric() {
        let rollups = [rollup(daysAgo: 1, dfa1Mean: 1.0, dfa1SD: 0.1),
                       rollup(daysAgo: 2, dfa1Mean: 1.2, dfa1SD: 0.1),
                       rollup(daysAgo: 3)]
        let ref = LiveDayComparison.reference(rollups: rollups, before: today)
        XCTAssertEqual(ref?.stat(for: .dfa1)?.n, 2)
        XCTAssertEqual(ref?.stat(for: .dfa1)?.mean ?? 0, 1.1, accuracy: 0.001)
        XCTAssertEqual(ref?.stat(for: .hr)?.n, 3)
    }

    // MARK: - Delta

    private func hrReference(mean: Double, sd: Double = 8) -> LiveDayReference {
        LiveDayComparison.reference(
            rollups: [rollup(daysAgo: 1, hrMean: mean, hrSD: sd),
                      rollup(daysAgo: 2, hrMean: mean, hrSD: sd)],
            before: today)!
    }

    func testPercentIsValueVsReferenceMean() {
        let d = LiveDayDelta.compute(value: 66, metric: .hr, reference: hrReference(mean: 60))
        XCTAssertEqual(d?.percent ?? 0, 10, accuracy: 0.01)
    }

    /// Pulse is lower-better: a rise is adverse even though the percent is +.
    func testLowerBetterSign() {
        let ref = hrReference(mean: 60)
        XCTAssertEqual(LiveDayDelta.compute(value: 66, metric: .hr, reference: ref)?.beneficial, false)
        XCTAssertEqual(LiveDayDelta.compute(value: 54, metric: .hr, reference: ref)?.beneficial, true)
    }

    /// Harmony's optimum is a target: moving from 1.4 down to 1.1 is toward
    /// 1.0 and must read as beneficial despite the negative percent — the bug
    /// the old boolean tile flag had.
    func testTargetDirectionColorsByDistanceToTarget() {
        let ref = LiveDayComparison.reference(
            rollups: [rollup(daysAgo: 1, dfa1Mean: 1.4, dfa1SD: 0.1),
                      rollup(daysAgo: 2, dfa1Mean: 1.4, dfa1SD: 0.1)],
            before: today)!
        let toward = LiveDayDelta.compute(value: 1.1, metric: .dfa1, reference: ref)
        XCTAssertLessThan(toward?.percent ?? 0, 0)
        XCTAssertEqual(toward?.beneficial, true)
        let past = LiveDayDelta.compute(value: 1.8, metric: .dfa1, reference: ref)
        XCTAssertEqual(past?.beneficial, false)
    }

    func testZeroReferenceMeanYieldsNoDelta() {
        XCTAssertNil(LiveDayDelta.compute(value: 5, metric: .hr, reference: hrReference(mean: 0)))
    }

    // MARK: - Intensity bands

    private func delta(z: Float) -> LiveDayDelta {
        LiveDayDelta(percent: 10, z: z, beneficial: true, referenceMean: 60)
    }

    func testInsideNoiseBandIsNeutralWithZeroIntensity() {
        XCTAssertTrue(delta(z: 0.49).neutral)
        XCTAssertTrue(delta(z: -0.49).neutral)
        XCTAssertEqual(delta(z: 0.49).intensity, 0)
    }

    func testIntensityRampsFromBandEdgeToSaturation() {
        XCTAssertFalse(delta(z: 0.5).neutral)
        XCTAssertEqual(delta(z: 0.5).intensity,  0.35, accuracy: 0.001)
        XCTAssertEqual(delta(z: 1.25).intensity, 0.675, accuracy: 0.001)
        XCTAssertEqual(delta(z: 2.0).intensity,  1.0,  accuracy: 0.001)
        XCTAssertEqual(delta(z: -3.0).intensity, 1.0,  accuracy: 0.001)
    }
}
