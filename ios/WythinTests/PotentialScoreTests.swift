import XCTest
@testable import Wythin

final class PotentialScoreTests: XCTestCase {

    private func baseline(lnMean: Float = 3.6, lnSD: Float = 0.2,
                          hrMean: Float = 60, hrSD: Float = 4,
                          dcMean: Float? = 7.5, dcSD: Float = 1,
                          pipMean: Float? = 40, pipSD: Float = 5,
                          cv7: Float? = nil, cv7Mean: Float = 0.05, cv7SD: Float = 0.01,
                          dfa1Median: Float? = 1.0) -> AnchorBaseline {
        AnchorBaseline(
            lnRMSSD:   BaselineStat(mean: lnMean, sd: lnSD, n: 30),
            restingHR: BaselineStat(mean: hrMean, sd: hrSD, n: 30),
            dc:        dcMean.map { BaselineStat(mean: $0, sd: dcSD, n: 30) },
            pip:       pipMean.map { BaselineStat(mean: $0, sd: pipSD, n: 30) },
            dfa1Median: dfa1Median,
            cv7:       cv7,
            cv7Stat:   BaselineStat(mean: cv7Mean, sd: cv7SD, n: 30),
            medianHour: 7,
            anchorCount: 30,
            hourMatched: true)
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

    func testTwoSDBelowSaturatesAtZero() {
        let r = PotentialScore.evaluate(
            anchor: anchor(ln: 3.2, hr: 68, dc: 5.5),
            baseline: baseline())
        XCTAssertEqual(r?.score, 0)
        XCTAssertEqual(r?.band, .depleted)
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

    func testBandBoundaries() {
        XCTAssertEqual(PotentialBand.forScore(85), .full)
        XCTAssertEqual(PotentialBand.forScore(79), .good)
        XCTAssertEqual(PotentialBand.forScore(59), .steady)
        XCTAssertEqual(PotentialBand.forScore(39), .light)
        XCTAssertEqual(PotentialBand.forScore(24), .depleted)
    }
}
