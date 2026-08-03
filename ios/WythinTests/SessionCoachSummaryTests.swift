import XCTest
@testable import Wythin

final class SessionCoachSummaryTests: XCTestCase {

    private func s(_ v: Int) -> AxisValue { .score(v, word: "typical") }
    private let none = AxisValue.unavailable(reason: "no fit")

    private func build(overall: AxisValue = .score(70, word: "well absorbed"),
                       suppression: AxisValue = .score(60, word: "typical"),
                       recovery: AxisValue = .score(60, word: "typical"),
                       efficiency: AxisValue = .score(60, word: "typical"),
                       load: Double? = 90,
                       moderate: Double = 30 * 60,
                       heavy: Double = 10 * 60,
                       severe: Double = 0,
                       loadPct: Double? = 0.5) -> SessionCoachSummary {
        .build(overall: overall, suppression: suppression, recovery: recovery,
               efficiency: efficiency, load: load,
               moderateSec: moderate, heavySec: heavy, severeSec: severe,
               loadPercentile: loadPct)
    }

    // MARK: - Strengths

    func testStrongRecoveryIsNamedAsAStrength() {
        // No percentage: recovery is a time now, and quoting a level here was
        // what let a still-falling session read as partly recovered.
        let c = build(recovery: s(82))
        XCTAssertTrue(c.strengths.contains { $0.lowercased().contains("came back quickly") })
    }

    func testThresholdTimeCountsAsRealTraining() {
        let c = build(heavy: 15 * 60)
        XCTAssertTrue(c.strengths.contains { $0.contains("15 minutes") })
    }

    func testThereIsAlwaysAtLeastOneStrength() {
        // Even the worst-scoring session did something worth saying.
        let c = build(overall: s(10), suppression: s(5), recovery: s(5),
                      efficiency: s(5), moderate: 0, heavy: 0, severe: 0, loadPct: 0)
        XCTAssertFalse(c.strengths.isEmpty)
    }

    func testUnavailableAxesProduceNoFalseClaims() {
        let c = build(overall: none, suppression: none, recovery: none,
                      efficiency: none, moderate: 0, heavy: 0, loadPct: nil)
        for line in c.strengths + c.improvements {
            XCTAssertFalse(line.contains("%"), "no percentage may be quoted without a score")
        }
    }

    // MARK: - Improvements

    func testSlowRecoveryEarnsAConcreteAction() {
        let c = build(recovery: s(22))
        let line = c.improvements.first { $0.lowercased().contains("slow to come back") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("breathing"), "a criticism must carry an action")
    }

    func testCostlySuppressionBlamesTheArrivalNotTheSession() {
        let c = build(suppression: s(15))
        let line = c.improvements.first { $0.contains("cost more vagal tone") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("under-recovered"))
    }

    func testAGoodSessionNeedsNoImprovements() {
        let c = build(suppression: s(85), recovery: s(85), efficiency: s(85),
                      heavy: 12 * 60, loadPct: 0.6)
        XCTAssertTrue(c.improvements.isEmpty)
    }

    // MARK: - The next session

    func testSlowRecoverySendsYouEasy() {
        XCTAssertTrue(build(recovery: s(20)).nextSession.lowercased().contains("easy"))
    }

    func testABigSessionAsksFor48Hours() {
        XCTAssertTrue(build(severe: 8 * 60).nextSession.contains("48 hours"))
    }

    func testAnAllEasySessionSuggestsAddingIntensity() {
        let c = build(moderate: 40 * 60, heavy: 0, severe: 0, loadPct: 0.2)
        XCTAssertTrue(c.nextSession.contains("threshold"))
    }

    func testThereIsAlwaysANextSession() {
        XCTAssertFalse(build().nextSession.isEmpty)
    }

    // MARK: - Copy rules

    func testNothingScolds() {
        let variants: [SessionCoachSummary] = [
            build(), build(recovery: s(10)), build(suppression: s(10)),
            build(severe: 10 * 60), build(overall: none, suppression: none,
                                          recovery: none, efficiency: none),
        ]
        for c in variants {
            for line in c.strengths + c.improvements + [c.nextSession] {
                let l = line.lowercased()
                for banned in ["poor", "bad", "failed", "wrong of you", "you should have"] {
                    XCTAssertFalse(l.contains(banned), "\"\(line)\"")
                }
            }
        }
    }
}
