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
        XCTAssertEqual(ActivityImpact.caption(for: -2.1), "stirred")
        XCTAssertEqual(ActivityImpact.caption(for: -10), "stirred")
        XCTAssertEqual(ActivityImpact.caption(for: -10.1), "strongly stirred")
    }

    func testHardEffortIsNotCalledALightSession() {
        // A run legitimately posts a large negative delta. It must read as
        // effort, not as a poor session.
        XCTAssertEqual(ActivityImpact.caption(for: -35), "strongly stirred")
    }

    // MARK: trend line

    func testTrendLineCountsMetricsBeatingBaseline() {
        let moves = [
            MetricMovement(name: "RSA", uplift: 12, vs2mo: 5),
            MetricMovement(name: "HRV", uplift: 15, vs2mo: 6),
            MetricMovement(name: "Calm Power", uplift: 1,  vs2mo: -1),
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
    // The headline percentage is a mean over however many of the named metrics
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
        XCTAssertEqual(e.impactCoverage.summary, "avg of 1/8 metrics")
    }

    /// A zero baseline is a distinct exclusion from a missing one — the reading
    /// exists, the percentage just isn't defined.
    func testAZeroBaselineIsExcludedForItsOwnReason() {
        let e = ActivityLog(activityType: "Breathwork")
        e.beforeRMSSD = 0; e.duringRMSSD = 50

        guard let gap = e.impactCoverage.missing.first(where: { $0.label == "Calm Power" }) else {
            return XCTFail("a zero baseline should be reported missing")
        }
        XCTAssertTrue(gap.reason.lowercased().contains("zero"), gap.reason)
    }
}

// MARK: - The caption must not collide with the session class

extension ImpactDeltaTests {

    func testNoCaptionReusesAWordThatNamesASessionClass() {
        // "activating" and "restorative" name which scoring model a session
        // gets. The impact caption describes how a practice left you. A yoga
        // session whose pulse rose 1% is correctly classed restorative and was
        // still captioned "activating", which reads as the app contradicting
        // itself on one row.
        let deltas: [Double] = [30, 12, 8, 4, 0, -5, -20, -40]
        for delta in deltas {
            XCTAssertFalse(ActivityImpact.caption(for: delta).contains("activating"),
                           "caption for \(delta) collides with the class name")
        }
    }

    func testTheStirredCaptionsCoverTheNegativeRange() {
        XCTAssertEqual(ActivityImpact.caption(for: -5), "stirred")
        XCTAssertEqual(ActivityImpact.caption(for: -25), "strongly stirred")
    }

    // MARK: Off the end of the scale
    //
    // benefitDelta clamps at ±100 so one ill-conditioned metric can't swamp the
    // mean. That is right for aggregation and wrong for display: printed bare,
    // a metric that doubled and one that went up eightfold both read "+100%",
    // while the absolute values under them plainly disagree. The display needs
    // to know which values are measurements and which are bounds.

    private var dc: ActivityMetricDef {
        activityMetricDefs.first { $0.label == "Vagal Tone" }!      // .higher
    }

    func testAChangeInsideTheScaleIsNotClamped() {
        XCTAssertEqual(dc.benefitDelta(current: 9, base: 6)!, 50, accuracy: 0.001)
        XCTAssertFalse(dc.isClamped(current: 9, base: 6))
    }

    /// Exactly double is exactly the bound — a real measurement, not a cap.
    func testAnExactDoublingSitsOnTheBoundWithoutBeingClamped() {
        XCTAssertEqual(dc.benefitDelta(current: 12, base: 6)!, 100, accuracy: 0.001)
        XCTAssertFalse(dc.isClamped(current: 12, base: 6),
                       "+100% reached honestly must not be marked as off-scale")
    }

    func testAChangeBeyondTheBoundIsClampedAndSaysSo() {
        XCTAssertEqual(dc.benefitDelta(current: 48, base: 6)!, 100, accuracy: 0.001)
        XCTAssertTrue(dc.isClamped(current: 48, base: 6))
        XCTAssertEqual(dc.rawBenefitDelta(current: 48, base: 6)!, 700, accuracy: 0.001)
    }

    /// A `.higher` metric can never reach −100%: its benefit is the value, and
    /// the value cannot go below zero. The negative bound is only reachable on a
    /// metric where lower is better, whose benefit falls without limit.
    func testAHigherIsBetterMetricCannotReachTheNegativeBound() {
        XCTAssertEqual(dc.benefitDelta(current: 0.5, base: 60)!, -99.1666, accuracy: 0.001)
        XCTAssertFalse(dc.isClamped(current: 0.5, base: 60))
    }

    func testTheNegativeBoundClampsOnALowerIsBetterMetric() {
        let hr = activityMetricDefs.first { $0.label == "Pulse" }!      // .lower
        XCTAssertEqual(hr.benefitDelta(current: 200, base: 60)!, -100, accuracy: 0.001)
        XCTAssertTrue(hr.isClamped(current: 200, base: 60))
        XCTAssertEqual(hr.rawBenefitDelta(current: 200, base: 60)!, -233.333, accuracy: 0.01)
    }

    /// The screenshot case: two metrics that moved very differently both read
    /// +100%, because both had run off the top of the scale.
    func testTwoDifferentOverflowsAreBothReportedAsClamped() {
        XCTAssertEqual(dc.benefitDelta(current: 14.3, base: 5)!,
                       dc.benefitDelta(current: 52.7, base: 5)!, accuracy: 0.001)
        XCTAssertTrue(dc.isClamped(current: 14.3, base: 5))
        XCTAssertTrue(dc.isClamped(current: 52.7, base: 5))
        XCTAssertNotEqual(dc.rawBenefitDelta(current: 14.3, base: 5)!,
                          dc.rawBenefitDelta(current: 52.7, base: 5)!,
                          "the underlying changes are not the same size")
    }

    func testMissingDataIsNotClamped() {
        XCTAssertFalse(dc.isClamped(current: nil, base: 6))
        XCTAssertFalse(dc.isClamped(current: 9, base: nil))
        XCTAssertFalse(dc.isClamped(current: 9, base: 0), "a zero baseline has no percentage at all")
    }
}
