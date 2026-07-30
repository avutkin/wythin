import XCTest
@testable import Wythin

final class AnchorBaselineTests: XCTestCase {

    private func reading(daysAgo: Int, lnRMSSD: Float, hr: Float = 60, hour: Double = 7) -> AnchorReading {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return AnchorReading(startedAt: start, durationSec: 300, hour: hour,
                             lnRMSSD: lnRMSSD, dc: 7.5, restingHR: hr, pip: 40, dfa1: 1.0,
                             breathBPM: 13, late: false, motionKnown: true, confidence: .high)
    }

    func testNilWithNoPriorAnchors() {
        XCTAssertNil(AnchorBaseline.build(history: [], todayHour: 7))
    }

    func testBuildsFromASinglePriorAnchor() {
        let b = AnchorBaseline.build(history: [reading(daysAgo: 1, lnRMSSD: 3.6)], todayHour: 7)
        XCTAssertNotNil(b)
        XCTAssertEqual(b?.lnRMSSD.n, 1)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.6, accuracy: 0.001)
    }

    func testProvisionalUntilFirmAnchorCount() {
        let six = (1...6).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        XCTAssertTrue(AnchorBaseline.build(history: six, todayHour: 7)?.provisional ?? false)

        let seven = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        XCTAssertFalse(AnchorBaseline.build(history: seven, todayHour: 7)?.provisional ?? true)
    }

    // MARK: - Prior-blended z

    /// At n = 1 there is no personal SD, so the blend is exactly the prior,
    /// widened by the prediction factor sqrt(1 + 1/1).
    func testSingleAnchorZUsesThePriorAlone() {
        let stat = BaselineStat(mean: 3.6, sd: 0, n: 1)
        let expected = 0.2 / (0.2 * Float(2).squareRoot())   // 0.7071
        XCTAssertEqual(stat.z(3.8, prior: 0.2) ?? 0, expected, accuracy: 0.001)
    }

    /// Spec §2.1 worked example: a spuriously tiny personal SD must not
    /// produce a monster z.
    func testTinyPersonalSDIsPulledTowardThePrior() {
        let stat = BaselineStat(mean: 3.6, sd: 0.05, n: 3)
        // sd_blend = sqrt((4*0.04 + 2*0.0025)/6) = 0.16583
        // sd_pred  = 0.16583 * sqrt(1 + 1/3) = 0.19148
        XCTAssertEqual(stat.z(3.6 + 0.19148, prior: 0.2) ?? 0, 1.0, accuracy: 0.002)

        // Naive z would have been 0.19148/0.05 = 3.83 — nearly 4x larger.
        let naive = 0.19148 / Float(0.05)
        XCTAssertLessThan(stat.z(3.6 + 0.19148, prior: 0.2) ?? 0, naive / 3)
    }

    func testPredictionWideningFadesAsAnchorsAccumulate() {
        let early = BaselineStat(mean: 3.6, sd: 0.2, n: 2)
        let late  = BaselineStat(mean: 3.6, sd: 0.2, n: 20)
        let zEarly = early.z(3.8, prior: 0.2) ?? 0
        let zLate  = late.z(3.8, prior: 0.2) ?? 0
        XCTAssertLessThan(zEarly, zLate)
        XCTAssertEqual(zEarly, 0.2 / (0.2 * 1.2247), accuracy: 0.01)   // n=2 → 1.22x
        XCTAssertEqual(zLate,  0.2 / (0.2 * 1.0247), accuracy: 0.01)   // n=20 → 1.02x
    }

    /// Identical anchors give sd = 0, which `z(_:)` rejects. With a prior in
    /// play the score must still be computable.
    // MARK: - Blended SD exposed for change-scores

    /// The nudge engine scores a *change* over 30 minutes, not a value against a
    /// mean, so it needs the blended SD as a denominator rather than a z. Same
    /// shrinkage as `z(_:prior:)` — the two must not drift apart.
    func testBlendedSDMatchesTheDenominatorUsedByZ() {
        let stat = BaselineStat(mean: 3.8, sd: 0.05, n: 3)
        let sd = stat.sdBlended(prior: 0.2) ?? 0
        // z of a value one blended-SD above the mean is exactly 1.
        XCTAssertEqual(stat.z(3.8 + sd, prior: 0.2) ?? 0, 1.0, accuracy: 0.001)
    }

    func testBlendedSDIsExactlyThePriorWideningAtASingleAnchor() {
        let stat = BaselineStat(mean: 3.8, sd: 0, n: 1)
        // n = 1: personal term zeroes, so blendVar is the prior; widened by √2.
        XCTAssertEqual(stat.sdBlended(prior: 0.2) ?? 0, 0.2 * Float(2).squareRoot(), accuracy: 0.001)
    }

    func testBlendedSDConvergesOnThePersonalSDWithManyAnchors() {
        let stat = BaselineStat(mean: 3.8, sd: 0.3, n: 200)
        XCTAssertEqual(stat.sdBlended(prior: 0.2) ?? 0, 0.3, accuracy: 0.005)
    }

    func testDegenerateSDStillYieldsAFiniteZ() {
        let stat = BaselineStat(mean: 3.6, sd: 0, n: 7)
        let z = stat.z(3.8, prior: 0.2)
        XCTAssertNotNil(z)
        XCTAssertTrue(z?.isFinite ?? false)
    }

    func testHourMatchingStillRequiresFirmAnchorCount() {
        let morning = (1...6).map { reading(daysAgo: $0, lnRMSSD: 3.6, hour: 7) }
        let evening = (8...14).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: morning + evening, todayHour: 7)
        XCTAssertFalse(b?.hourMatched ?? true)
    }

    func testComputesMeanAndSD() {
        let values: [Float] = [3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 4.0]
        let history = values.enumerated().map { reading(daysAgo: $0.offset + 1, lnRMSSD: $0.element) }
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.7, accuracy: 0.001)
        XCTAssertEqual(b?.lnRMSSD.n, 7)
        XCTAssertGreaterThan(b?.lnRMSSD.sd ?? 0, 0)
    }

    func testExcludesAnchorsOlderThanWindow() {
        var history = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6) }
        history.append(reading(daysAgo: 90, lnRMSSD: 99))
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertEqual(b?.lnRMSSD.n, 7)
    }

    func testPrefersAnchorsNearTodaysHour() {
        let morning = (1...7).map { reading(daysAgo: $0, lnRMSSD: 3.6, hour: 7) }
        let evening = (8...14).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: morning + evening, todayHour: 7)
        XCTAssertTrue(b?.hourMatched ?? false)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 3.6, accuracy: 0.001)
    }

    func testFallsBackToAllAnchorsWhenHourMatchTooSmall() {
        let evening = (1...8).map { reading(daysAgo: $0, lnRMSSD: 9.0, hour: 21) }
        let b = AnchorBaseline.build(history: evening, todayHour: 7)
        XCTAssertFalse(b?.hourMatched ?? true)
        XCTAssertEqual(b?.lnRMSSD.mean ?? 0, 9.0, accuracy: 0.001)
    }

    func testComputesRecentCV() {
        let values: [Float] = [3.0, 4.0, 3.0, 4.0, 3.0, 4.0, 3.0]
        let history = values.enumerated().map { reading(daysAgo: $0.offset + 1, lnRMSSD: $0.element) }
        let b = AnchorBaseline.build(history: history, todayHour: 7)
        XCTAssertGreaterThan(b?.cv7 ?? 0, 0.1)
    }
}
