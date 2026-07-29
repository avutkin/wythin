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
