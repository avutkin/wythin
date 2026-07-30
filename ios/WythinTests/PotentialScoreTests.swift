import XCTest
@testable import Wythin

final class PotentialScoreTests: XCTestCase {

    private func baseline(lnMean: Float = 3.6, lnSD: Float = 0.2,
                          hrMean: Float = 60, hrSD: Float = 4,
                          dcMean: Float? = 7.5, dcSD: Float = 1,
                          pipMean: Float? = 40, pipSD: Float = 5,
                          cv7: Float? = nil, cv7Mean: Float = 0.05, cv7SD: Float = 0.01,
                          dfa1Median: Float? = 1.0, n: Int = 30) -> AnchorBaseline {
        AnchorBaseline(
            lnRMSSD:   BaselineStat(mean: lnMean, sd: lnSD, n: n),
            restingHR: BaselineStat(mean: hrMean, sd: hrSD, n: n),
            dc:        dcMean.map { BaselineStat(mean: $0, sd: dcSD, n: n) },
            pip:       pipMean.map { BaselineStat(mean: $0, sd: pipSD, n: n) },
            dfa1Median: dfa1Median,
            cv7:       cv7,
            cv7Stat:   BaselineStat(mean: cv7Mean, sd: cv7SD, n: n),
            medianHour: 7,
            anchorCount: n,
            hourMatched: true,
            provisional: n < AnchorBaseline.firmAnchors)
    }

    private func anchor(ln: Float = 3.6, hr: Float = 60, dc: Float? = 7.5,
                        pip: Float? = 40, dfa1: Float? = 1.0, hour: Double = 7) -> AnchorReading {
        AnchorReading(startedAt: Date(), durationSec: 300, hour: hour,
                      lnRMSSD: ln, dc: dc, restingHR: hr, pip: pip, dfa1: dfa1,
                      breathBPM: 13, late: false, motionKnown: true, confidence: .high)
    }

    func testAtPersonalNormScoresFifty() {
        let r = PotentialScore.evaluate(anchor: anchor(), baseline: baseline())
        XCTAssertEqual(r?.score, 50)
        XCTAssertEqual(r?.band, .steady)
    }

    func testDeeplyRestedIsCappedBySaturationGuard() {
        // +2 SD on every core component — deep rest, not a peak.
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 4.0, hr: 52, dc: 9.5),
            baseline: baseline())
        XCTAssertEqual(r?.score, 75)
        XCTAssertTrue(r?.saturated ?? false)
    }

    func testTwoSDBelowIsDepleted() {
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 3.2, hr: 68, dc: 5.5),
            baseline: baseline())
        XCTAssertEqual(r?.band, .depleted)
        XCTAssertLessThanOrEqual(r?.score ?? 99, 5)
    }

    /// The floor holds however far below the norm the anchor sits. Two SD no
    /// longer reaches it: prediction widening shrinks every z slightly, so it
    /// lands at 1 rather than 0.
    func testFarBelowNormClampsAtZero() {
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 2.8, hr: 76, dc: 3.5),
            baseline: baseline())
        XCTAssertEqual(r?.score, 0)
    }

    func testFragmentationPenaltyCapsAtTen() {
        // +4 SD of PIP would be −20 uncapped.
        let r = PotentialScore.evaluate(
            anchor: anchor(pip: 60),
            baseline: baseline())
        XCTAssertEqual(r?.penalties.fragmentation ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(r?.score, 40)
    }

    func testStabilityPenaltyApplies() {
        let r = PotentialScore.evaluate(
            anchor: anchor(),
            baseline: baseline(cv7: 0.07))   // +2 SD of CV7 → −10
        XCTAssertEqual(r?.penalties.stability ?? 0, 10, accuracy: 0.001)
    }

    func testOrganizationPenaltyCapsAtFive() {
        let r = PotentialScore.evaluate(
            anchor: anchor(dfa1: 0.2),
            baseline: baseline())
        XCTAssertEqual(r?.penalties.organization ?? 0, 5, accuracy: 0.001)
    }

    func testMissingDCRedistributesWeight() {
        let r = PotentialScore.evaluate(anchor: anchor(dc: nil), baseline: baseline())
        XCTAssertNil(r?.components.dcZ)
        XCTAssertEqual(r?.score, 50, "at norm the redistribution is still 50")
    }

    func testRejectsAnchorFarFromUsualHour() {
        XCTAssertNil(PotentialScore.evaluate(anchor: anchor(hour: 15), baseline: baseline()))
    }

    // MARK: - Provisional baselines

    private func series(_ values: [Float], todayHour: Double = 7) -> AnchorBaseline? {
        let history = values.enumerated().map { idx, v -> AnchorReading in
            let start = Calendar.current.date(byAdding: .day, value: -(idx + 1), to: Date())!
            return AnchorReading(startedAt: start, durationSec: 300, hour: 7,
                                 lnRMSSD: v, dc: 7.5, restingHR: 60, pip: 40, dfa1: 1.0,
                                 breathBPM: 13, late: false, motionKnown: true, confidence: .high)
        }
        return AnchorBaseline.build(history: history, todayHour: todayHour)
    }

    /// The whole point of the prior. A tiny sample SD would give z = 10 and peg
    /// the score at 100; blended, the same anchor must read as merely good.
    func testTinySampleSDCannotPegTheScore() {
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 3.8),
            baseline: baseline(lnMean: 3.6, lnSD: 0.02, n: 3))
        XCTAssertNotNil(r)
        XCTAssertLessThan(r?.score ?? 100, 85)
    }

    /// The core promise: the label changes at seven anchors, the number does not
    /// jump. The 7th value equals the mean of the first 6, so any movement here
    /// comes from the mechanism rather than from new data.
    func testScoreIsContinuousAcrossTheFirmBoundary() {
        let values: [Float] = [3.4, 3.5, 3.6, 3.6, 3.7, 3.8]
        guard let six = series(values), let seven = series(values + [3.6]) else {
            return XCTFail("baseline should build at both 6 and 7 anchors")
        }
        XCTAssertTrue(six.provisional)
        XCTAssertFalse(seven.provisional)

        let a = anchor(ln: 3.8)
        guard let s6 = PotentialScore.evaluate(anchor: a, baseline: six)?.score,
              let s7 = PotentialScore.evaluate(anchor: a, baseline: seven)?.score else {
            return XCTFail("both should score")
        }
        XCTAssertLessThanOrEqual(abs(s6 - s7), 3, "score jumped \(s6) → \(s7) at the boundary")
    }

    /// The penalty ramp and the label change must not land on the same day, or
    /// the continuity above is destroyed by a 10-point drop.
    func testStabilityPenaltyIsZeroAtTheFirmBoundary() {
        let r = PotentialScore.evaluate(
            anchor: anchor(),
            baseline: baseline(cv7: 0.07, n: 7))
        XCTAssertEqual(r?.penalties.stability ?? -1, 0, accuracy: 0.001)
    }

    func testStabilityPenaltyRampsInAfterTheBoundary() {
        let at8  = PotentialScore.evaluate(anchor: anchor(), baseline: baseline(cv7: 0.07, n: 8))
        let at11 = PotentialScore.evaluate(anchor: anchor(), baseline: baseline(cv7: 0.07, n: 11))
        XCTAssertEqual(at8?.penalties.stability ?? 0, 2.5, accuracy: 0.001)   // 10 * (8-7)/4
        XCTAssertEqual(at11?.penalties.stability ?? 0, 10, accuracy: 0.001)   // full
    }

    func testBandBoundaries() {
        XCTAssertEqual(PotentialBand.forScore(85), .full)
        XCTAssertEqual(PotentialBand.forScore(79), .good)
        XCTAssertEqual(PotentialBand.forScore(59), .steady)
        XCTAssertEqual(PotentialBand.forScore(39), .light)
        XCTAssertEqual(PotentialBand.forScore(24), .depleted)
    }
}
