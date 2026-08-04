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

    func testRisingVagalToneIsFlaggedRatherThanDiscarded() {
        // Yoga and mobility work really do raise vagal tone as heart rate
        // lifts. Discarding that as noise described the app's confusion rather
        // than the person's session — it is a real fit, flagged, and left
        // unscored so it is never ranked against sessions that suppressed.
        let rising = stride(from: 30.0, through: 80.0, by: 5.0).map {
            (hrrPct: $0, dc: exp(1.0 + 0.02 * $0), dfa1: Double?(1.0))
        }
        let fit = ExerciseSuppression.vsi(samples: rising)
        XCTAssertNotNil(fit)
        XCTAssertTrue(fit!.vagalRose)
        XCTAssertGreaterThan(fit!.slopePer10, 0)
    }

    func testASuppressingSessionIsNotFlaggedAsRising() {
        let falling = stride(from: 30.0, through: 80.0, by: 5.0).map { synthetic(hrr: $0) }
        XCTAssertFalse(ExerciseSuppression.vsi(samples: falling)!.vagalRose)
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

// MARK: - Brake per beat (the always-available form)

extension ExerciseSuppressionTests {

    func testBrakePerBeatIsMillisecondsOfBrakePerExtraBeat() {
        // DC 9 → 3 is 6 ms of brake released; HR 60 → 120 is 60 extra beats.
        let v = ExerciseSuppression.brakePerBeat(dcPre: 9, dcDuring: 3,
                                                 hrPre: 60, hrDuring: 120)
        XCTAssertEqual(v!, 0.1, accuracy: 0.0001)
    }

    func testACheaperSessionGivesUpLessBrakePerBeat() {
        let costly = ExerciseSuppression.brakePerBeat(dcPre: 9, dcDuring: 2,
                                                      hrPre: 60, hrDuring: 120)!
        let cheap  = ExerciseSuppression.brakePerBeat(dcPre: 9, dcDuring: 6,
                                                      hrPre: 60, hrDuring: 120)!
        XCTAssertLessThan(cheap, costly)
    }

    func testNoMeaningfulHeartRateRiseYieldsNothing() {
        // Dividing by a near-zero ΔHR inflates the ratio for no reason.
        XCTAssertNil(ExerciseSuppression.brakePerBeat(dcPre: 9, dcDuring: 8,
                                                      hrPre: 60, hrDuring: 62))
    }

    func testMissingWindowsYieldNothing() {
        XCTAssertNil(ExerciseSuppression.brakePerBeat(dcPre: nil, dcDuring: 3,
                                                      hrPre: 60, hrDuring: 120))
        XCTAssertNil(ExerciseSuppression.brakePerBeat(dcPre: 9, dcDuring: 3,
                                                      hrPre: 60, hrDuring: nil))
    }

    func testItWorksWhereTheSlopeCannotBeFitted() {
        // The whole point: two window averages are enough, so a lifting session
        // with no usable per-sample DC still gets a Suppression reading.
        XCTAssertNotNil(ExerciseSuppression.brakePerBeat(dcPre: 8.4, dcDuring: 5.1,
                                                         hrPre: 62, hrDuring: 104))
    }
}

// MARK: - The span guard is expressed in the units of x

extension ExerciseSuppressionTests {

    func testTheSpanGuardUsesTheCallersUnits() {
        // Motion in milli-g with only 6 mg of spread: acceptable under the %HRR
        // default of 5, rejected under the motion floor of 8. One constant
        // across two units silently accepted fits it should have refused.
        let narrow = stride(from: 20.0, through: 26.0, by: 1.0).map {
            (hrrPct: $0, dc: exp(2.0 - 0.02 * $0), dfa1: Double?(1.0))
        }
        XCTAssertNotNil(ExerciseSuppression.vsi(samples: narrow))
        XCTAssertNil(ExerciseSuppression.vsi(
            samples: narrow, minimumSpan: ExerciseSuppression.minimumMotionSpan))
    }

    func testAWideEnoughMotionSpanStillFits() {
        let wide = stride(from: 10.0, through: 60.0, by: 5.0).map {
            (hrrPct: $0, dc: exp(2.0 - 0.02 * $0), dfa1: Double?(1.0))
        }
        XCTAssertNotNil(ExerciseSuppression.vsi(
            samples: wide, minimumSpan: ExerciseSuppression.minimumMotionSpan))
    }
}

// MARK: - The economy score exists from session one

extension ExerciseSuppressionTests {

    func testCheapWorkScoresTopAndCostlyWorkScoresBottom() {
        XCTAssertEqual(ExerciseSuppression.economyScore(
            brakePerBeat: ExerciseSuppression.cheapBrakePerBeat), 100)
        XCTAssertEqual(ExerciseSuppression.economyScore(
            brakePerBeat: ExerciseSuppression.costlyBrakePerBeat), 0)
    }

    func testTheScoreFallsAsTheCostRises() {
        let scores = [0.04, 0.08, 0.12, 0.16, 0.20]
            .map { ExerciseSuppression.economyScore(brakePerBeat: $0)! }
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testBeyondTheAnchorsItClampsRatherThanOverflowing() {
        XCTAssertEqual(ExerciseSuppression.economyScore(brakePerBeat: 0.001), 100)
        XCTAssertEqual(ExerciseSuppression.economyScore(brakePerBeat: 5.0), 0)
    }

    func testNoIndexMeansNoScore() {
        XCTAssertNil(ExerciseSuppression.economyScore(brakePerBeat: nil))
    }

    func testItNeedsNoHistoryAtAll() {
        // The bug this fixes: every axis was a percentile, so the first three
        // sessions of a kind had no scoreable axis and therefore no session
        // score. This one is anchored, so it exists immediately.
        XCTAssertNotNil(ExerciseSuppression.economyScore(brakePerBeat: 0.08))
    }
}
