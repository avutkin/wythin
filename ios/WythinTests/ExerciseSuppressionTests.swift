import XCTest
@testable import Wythin

final class ExerciseSuppressionTests: XCTestCase {

    /// lnDC = 2.0 − 0.02·hrr, so the true slope is −0.20 per 10 %HRR.
    private func synthetic(hrr: Double, dfa1: Double? = 1.0)
        -> (hrrPct: Double, dc: Double, dfa1: Double?) {
        (hrrPct: hrr, dc: exp(2.0 - 0.02 * hrr), dfa1: dfa1)
    }

    // MARK: - The fit

    func testSlopeRecoversAKnownRelationship() {
        let samples = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        let fit = ExerciseSuppression.vsi(samples: samples)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.slopePer10, -0.20, accuracy: 0.0001)
        XCTAssertEqual(fit!.sampleCount, samples.count)
    }

    func testSevereDomainSamplesAreExcludedFromTheFit() {
        // DC floors in the severe domain: the numerator physically cannot fall
        // further while the denominator keeps climbing. Including those points
        // measures the floor, not the person.
        var samples = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        samples += (85...95).map { (hrrPct: Double($0), dc: 0.05, dfa1: Double?(0.30)) }
        let fit = ExerciseSuppression.vsi(samples: samples)
        XCTAssertEqual(fit!.slopePer10, -0.20, accuracy: 0.0001,
                       "severe-domain points must not steepen the fit")
        XCTAssertEqual(fit!.sampleCount, 11)
    }

    func testSamplesWithUnknownDomainAreKept() {
        // A nil a1 is missing data, not evidence of the severe domain.
        let samples = stride(from: 30.0, through: 80.0, by: 5.0).map {
            synthetic(hrr: $0, dfa1: nil)
        }
        XCTAssertEqual(ExerciseSuppression.vsi(samples: samples)!.slopePer10,
                       -0.20, accuracy: 0.0001)
    }

    func testNonPositiveDCIsRejected() {
        // ln(0) is -infinity and ln of a negative is NaN — both would poison the
        // regression rather than merely perturb it.
        var samples = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        samples.append((hrrPct: 60, dc: 0, dfa1: 1.0))
        samples.append((hrrPct: 65, dc: -3, dfa1: 1.0))
        let fit = ExerciseSuppression.vsi(samples: samples)
        XCTAssertEqual(fit!.slopePer10, -0.20, accuracy: 0.0001)
        XCTAssertFalse(fit!.slopePer10.isNaN)
    }

    func testTooFewPointsYieldsNoFit() {
        XCTAssertNil(ExerciseSuppression.vsi(samples: [synthetic(hrr: 40)]))
        XCTAssertNil(ExerciseSuppression.vsi(samples: []))
    }

    func testCollapsedHRRSpanYieldsNoFit() {
        // Every point at the same intensity — the slope is undefined, not zero.
        let samples = (0..<10).map { _ in synthetic(hrr: 55) }
        XCTAssertNil(ExerciseSuppression.vsi(samples: samples))
    }

    func testSteeperSlopeMeansCostlier() {
        let usual = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        let costly = stride(from: 30.0, through: 80.0, by: 5.0).map {
            (hrrPct: $0, dc: exp(2.0 - 0.03 * $0), dfa1: Double?(1.0))
        }
        XCTAssertLessThan(ExerciseSuppression.vsi(samples: costly)!.slopePer10,
                          ExerciseSuppression.vsi(samples: usual)!.slopePer10)
    }

    func testAWholeSessionOfSevereWorkYieldsNoFit() {
        // Nothing survives exclusion, so the honest answer is no fit at all
        // rather than a slope derived from the DC floor.
        let samples = (70...95).map { (hrrPct: Double($0), dc: 0.05, dfa1: Double?(0.3)) }
        XCTAssertNil(ExerciseSuppression.vsi(samples: samples))
    }

    // MARK: - Depth

    func testDepthIsTheFractionOfVagalToneWithdrawn() {
        XCTAssertEqual(ExerciseSuppression.depth(dcTrough: 2.5, dcPre: 10)!,
                       0.75, accuracy: 0.0001)
    }

    func testDepthClampsAndRejectsAnUnusableBaseline() {
        XCTAssertEqual(ExerciseSuppression.depth(dcTrough: 12, dcPre: 10)!, 0,
                       "a trough above baseline is no withdrawal, not negative withdrawal")
        XCTAssertNil(ExerciseSuppression.depth(dcTrough: 2, dcPre: 0))
    }
}
