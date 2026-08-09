import XCTest
@testable import Wythin

final class ImpactDeltaTests: XCTestCase {

    func testDeltaIsTheMeanOfPerMetricBenefitDeltas() {
        let e = ActivityLog(activityType: "Meditation")
        // RSA higher-is-better: 40 → 44 is +10%.
        e.beforeRSA = 40; e.duringRSA = 44
        // HR lower-is-better: 60 → 54 is a 10% benefit.
        e.beforeHR = 60;  e.duringHR = 54
        let d = e.impactDeltaPct
        XCTAssertNotNil(d)
        XCTAssertEqual(d!, 10, accuracy: 0.001)
    }

    func testFallingPulseIsAPositiveDelta() {
        let e = ActivityLog(activityType: "Meditation")
        e.beforeHR = 60; e.duringHR = 54
        XCTAssertEqual(e.impactDeltaPct!, 10, accuracy: 0.001)
    }

    func testRisingPulseIsANegativeDelta() {
        let e = ActivityLog(activityType: "Run")
        e.beforeHR = 60; e.duringHR = 90
        XCTAssertEqual(e.impactDeltaPct!, -50, accuracy: 0.001)
    }

    func testMetricsMissingEitherWindowAreIgnored() {
        let e = ActivityLog(activityType: "Walk")
        e.beforeRSA = 40; e.duringRSA = 44   // counted
        e.beforeHR  = 60                      // no during — ignored
        e.duringVTI = 3.5                     // no before — ignored
        XCTAssertEqual(e.impactDeltaPct!, 10, accuracy: 0.001)
    }

    func testNilWhenNoMetricHasBothWindows() {
        XCTAssertNil(ActivityLog(activityType: "Walk").impactDeltaPct)
    }

    // MARK: benefitDelta edge cases

    func testTargetDirectionDeltaIsClampedToOneHundred() {
        // Harmony (DFA α1) targets 1.0, so its benefit is -|x - 1|. A healthy,
        // near-target before-window makes the divisor tiny, so a modest move
        // in `during` would otherwise blow up far past ±100%.
        // benefit(0.98) = -0.02, benefit(0.85) = -0.15.
        // Raw = (-0.15 - -0.02) / 0.02 * 100 = -650%, clamped to -100.
        let dfa1 = activityMetricDefs.first { $0.techLabel == "DFA α1" }!
        let raw = dfa1.benefitDelta(current: 0.85, base: 0.98)
        XCTAssertEqual(raw!, -100, accuracy: 0.001)

        // The headline mean must reflect the clamped value, not the raw one —
        // it's the only metric present, so an unclamped -650 would show here.
        let e = ActivityLog(activityType: "Meditation")
        e.beforeDFA1 = 0.98; e.duringDFA1 = 0.85
        XCTAssertEqual(e.impactDeltaPct!, -100, accuracy: 0.001)
    }

    func testZeroBaseBenefitMetricIsSkippedFromTheMean() {
        // Harmony exactly at its target (benefit(1.0) == 0) has no valid
        // percent divisor and is silently excluded from the mean, even
        // though both its before and during windows are present.
        let dfa1 = activityMetricDefs.first { $0.techLabel == "DFA α1" }!
        XCTAssertNil(dfa1.benefitDelta(current: 0.9, base: 1.0))

        let e = ActivityLog(activityType: "Meditation")
        e.beforeRSA = 40; e.duringRSA = 44        // counted, +10%
        e.beforeDFA1 = 1.0; e.duringDFA1 = 0.9    // base benefit == 0 — skipped
        XCTAssertEqual(e.impactDeltaPct!, 10, accuracy: 0.001)
    }

    // MARK: captions

    func testCaptionBoundaries() {
        XCTAssertEqual(ActivityImpact.caption(for: 12),  "deeply restorative")
        XCTAssertEqual(ActivityImpact.caption(for: 11.9), "restorative")
        XCTAssertEqual(ActivityImpact.caption(for: 6),   "restorative")
        XCTAssertEqual(ActivityImpact.caption(for: 5.9), "settling")
        XCTAssertEqual(ActivityImpact.caption(for: 2),   "settling")
        XCTAssertEqual(ActivityImpact.caption(for: 1.9), "steady")
        XCTAssertEqual(ActivityImpact.caption(for: -2),  "steady")
        XCTAssertEqual(ActivityImpact.caption(for: -2.1), "activating")
        XCTAssertEqual(ActivityImpact.caption(for: -10), "activating")
        XCTAssertEqual(ActivityImpact.caption(for: -10.1), "strongly activating")
    }

    func testHardEffortIsNotCalledALightSession() {
        // A run legitimately posts a large negative delta. It must read as
        // effort, not as a poor session.
        XCTAssertEqual(ActivityImpact.caption(for: -35), "strongly activating")
    }

    // MARK: trend line

    func testTrendLineCountsMetricsBeatingBaseline() {
        let moves = [
            MetricMovement(name: "RSA", uplift: 12, vs2mo: 5),
            MetricMovement(name: "HRV", uplift: 15, vs2mo: 6),
            MetricMovement(name: "VTI", uplift: 1,  vs2mo: -1),
            MetricMovement(name: "HR",  uplift: 3,  vs2mo: nil),
        ]
        XCTAssertEqual(ActivityImpact.trendLine(moves),
                       "You beat your 2-month average on 2 of 3 metrics.")
    }

    func testTrendLineNilWithoutBaseline() {
        let moves = [MetricMovement(name: "RSA", uplift: 12, vs2mo: nil)]
        XCTAssertNil(ActivityImpact.trendLine(moves))
    }
}

extension ImpactDeltaTests {

    func testMeterCentresOnZero() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(0), 0.5, accuracy: 0.0001)
    }

    func testMeterEndsAtTheDomainBounds() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(20), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PracticeImpactMeter.fillFraction(-20), 0.0, accuracy: 0.0001)
    }

    func testMeterIsLinearInBetween() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(10), 0.75, accuracy: 0.0001)
        XCTAssertEqual(PracticeImpactMeter.fillFraction(-10), 0.25, accuracy: 0.0001)
    }

    func testMeterClampsBeyondTheDomain() {
        XCTAssertEqual(PracticeImpactMeter.fillFraction(85), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PracticeImpactMeter.fillFraction(-85), 0.0, accuracy: 0.0001)
        XCTAssertTrue(PracticeImpactMeter.isClamped(85))
        XCTAssertTrue(PracticeImpactMeter.isClamped(-21))
        XCTAssertFalse(PracticeImpactMeter.isClamped(19))
    }

    // MARK: Coverage
    //
    // The headline percentage is a mean over however many of the nine metrics
    // had both a before and a during value. That denominator is now shown to the
    // user, so it has to be exactly the one the mean used — a coverage line that
    // disagrees with the number beside it is worse than no coverage line.

    func testCoverageCountsExactlyTheMetricsTheMeanUsed() {
        let e = ActivityLog(activityType: "Breathwork")
        // Two metrics with a full before/during pair, the rest bare.
        e.beforeHR    = 70;  e.duringHR    = 63
        e.beforeRMSSD = 40;  e.duringRMSSD = 50

        let coverage = e.impactCoverage
        XCTAssertEqual(coverage.counted, 2)
        XCTAssertEqual(coverage.total, activityMetricDefs.count)
        XCTAssertEqual(coverage.missing.count, activityMetricDefs.count - 2)
        XCTAssertFalse(coverage.isComplete)
    }

    func testCoverageIsCompleteWhenNothingIsMissing() {
        let e = ActivityLog(activityType: "Breathwork")
        XCTAssertTrue(e.impactCoverage.missing.isEmpty == false,
                      "precondition: a bare entry has gaps")

        // Fill every metric's before/during pair.
        e.beforeHR = 70;      e.duringHR = 63
        e.beforeRMSSD = 40;   e.duringRMSSD = 50
        e.beforeRSA = 30;     e.duringRSA = 45
        e.beforeVTI = 3.6;    e.duringVTI = 3.9
        e.beforeStress = 50;  e.duringStress = 44
        e.beforeRCMSE = 1.0;  e.duringRCMSE = 1.5
        e.beforePIP = 40;     e.duringPIP = 34
        e.beforeDC = 6;       e.duringDC = 9
        e.beforeDFA1 = 0.9;   e.duringDFA1 = 1.0

        let coverage = e.impactCoverage
        XCTAssertTrue(coverage.isComplete, "missing: \(coverage.missing.map(\.label))")
        XCTAssertEqual(coverage.counted, activityMetricDefs.count)
        XCTAssertTrue(coverage.missing.isEmpty)
        XCTAssertNotNil(e.impactDeltaPct)
    }

    /// The exact case on screen: Vagal Tone has a during value but no baseline,
    /// so it shows a number with no percentage and must be reported as excluded.
    func testAMetricWithNoBaselineIsExcludedAndExplained() {
        let e = ActivityLog(activityType: "Breathwork")
        e.beforeHR = 70; e.duringHR = 63
        e.duringDC = 32                      // during only — no beforeDC

        let coverage = e.impactCoverage
        guard let gap = coverage.missing.first(where: { $0.label == "Vagal Tone" }) else {
            return XCTFail("Vagal Tone should be reported missing")
        }
        XCTAssertTrue(gap.reason.contains("baseline"),
                      "the reason should name the missing baseline: \(gap.reason)")
        XCTAssertTrue(gap.reason.contains("2½ minutes"),
                      "DC's warm-up is why it drops out first: \(gap.reason)")
    }

    func testEveryGapCarriesANonEmptyReason() {
        let e = ActivityLog(activityType: "Breathwork")
        for gap in e.impactCoverage.missing {
            XCTAssertFalse(gap.reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(gap.label): no reason given")
        }
    }

    func testSummaryNamesBothSidesOfTheFraction() {
        let e = ActivityLog(activityType: "Breathwork")
        e.beforeHR = 70; e.duringHR = 63
        XCTAssertEqual(e.impactCoverage.summary, "avg of 1/9 metrics")
    }

    /// A zero baseline is a distinct exclusion from a missing one — the reading
    /// exists, the percentage just isn't defined.
    func testAZeroBaselineIsExcludedForItsOwnReason() {
        let e = ActivityLog(activityType: "Breathwork")
        e.beforeRMSSD = 0; e.duringRMSSD = 50

        guard let gap = e.impactCoverage.missing.first(where: { $0.label == "Energy Reserve" }) else {
            return XCTFail("a zero baseline should be reported missing")
        }
        XCTAssertTrue(gap.reason.lowercased().contains("zero"), gap.reason)
    }
}
