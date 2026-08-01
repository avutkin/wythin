import XCTest
@testable import Wythin

final class ExerciseIntensityTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1000)
    private func t(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

    // MARK: - %HR reserve

    func testHRReserveIsFractionOfTheSpan() {
        // resting 50, ceiling 190 → span 140. hr 120 → 70/140 = 0.5
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 120, restingHR: 50, ceiling: 190),
                       0.5, accuracy: 0.0001)
    }

    func testHRReserveClampsToUnitInterval() {
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 40, restingHR: 50, ceiling: 190), 0)
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 250, restingHR: 50, ceiling: 190), 1)
    }

    func testHRReserveIsZeroWhenTheSpanCollapses() {
        XCTAssertEqual(ExerciseIntensity.hrReserve(hr: 120, restingHR: 190, ceiling: 190), 0)
    }

    // MARK: - Load

    func testLoadOfOneMinuteAtHalfReserve() {
        // x = 0.5, Δt = 1 min → 0.5 · e^(1.8·0.5) = 0.5 · 2.4596 = 1.2298
        let samples = [(date: t(0), hr: Float(120)), (date: t(60), hr: Float(120))]
        XCTAssertEqual(ExerciseIntensity.load(samples: samples, restingHR: 50, ceiling: 190),
                       1.2298, accuracy: 0.001)
    }

    func testLoadIsZeroAtRest() {
        let samples = [(date: t(0), hr: Float(50)), (date: t(600), hr: Float(50))]
        XCTAssertEqual(ExerciseIntensity.load(samples: samples, restingHR: 50, ceiling: 190),
                       0, accuracy: 0.0001)
    }

    func testHarderWorkCostsDisproportionatelyMore() {
        // The exponential weighting must make 10 min hard exceed 20 min easy.
        let easy = (0...20).map { (date: t(Double($0) * 60), hr: Float(85)) }   // x = 0.25
        let hard = (0...10).map { (date: t(Double($0) * 60), hr: Float(155)) }  // x = 0.75
        XCTAssertGreaterThan(ExerciseIntensity.load(samples: hard, restingHR: 50, ceiling: 190),
                             ExerciseIntensity.load(samples: easy, restingHR: 50, ceiling: 190))
    }

    func testLoadNeedsAtLeastTwoSamples() {
        XCTAssertEqual(ExerciseIntensity.load(samples: [(date: t(0), hr: Float(150))],
                                              restingHR: 50, ceiling: 190), 0)
    }

    func testLoadIgnoresLongGapsFromStrapDropout() {
        // A 40-minute gap must not be integrated as 40 minutes of work, or every
        // session with a dropout silently inflates.
        let samples = [(date: t(0), hr: Float(150)), (date: t(2400), hr: Float(150))]
        XCTAssertEqual(ExerciseIntensity.load(samples: samples, restingHR: 50, ceiling: 190),
                       0, accuracy: 0.0001)
    }

    func testLoadIsOrderIndependent() {
        let ordered = (0...10).map { (date: t(Double($0) * 60), hr: Float(140)) }
        XCTAssertEqual(ExerciseIntensity.load(samples: ordered.shuffled(),
                                              restingHR: 50, ceiling: 190),
                       ExerciseIntensity.load(samples: ordered, restingHR: 50, ceiling: 190),
                       accuracy: 0.0001)
    }

    // MARK: - Intensity domains

    func testDomainBoundaries() {
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 1.05), .moderate)
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.75), .moderate, "0.75 is the moderate edge")
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.74), .heavy)
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.50), .heavy, "0.5 is the heavy edge")
        XCTAssertEqual(ExerciseIntensity.domain(dfa1: 0.49), .severe)
    }

    func testDomainSplitSumsDurationsPerDomain() {
        let samples: [(date: Date, dfa1: Double)] = [
            (t(0),   1.0),   // moderate for 60 s
            (t(60),  1.0),   // moderate for 60 s
            (t(120), 0.6),   // heavy for 60 s
            (t(180), 0.4),   // severe — last sample carries no forward duration
        ]
        let split = ExerciseIntensity.domainSplit(samples: samples)
        XCTAssertEqual(split[.moderate] ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(split[.heavy] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(split[.severe] ?? 0, 0, accuracy: 0.001)
    }

    func testDomainSplitIsEmptyForASingleSample() {
        XCTAssertTrue(ExerciseIntensity.domainSplit(samples: [(t(0), 0.9)]).isEmpty)
    }

    func testDomainSplitIgnoresLongGaps() {
        let samples: [(date: Date, dfa1: Double)] = [(t(0), 1.0), (t(2400), 1.0)]
        XCTAssertTrue(ExerciseIntensity.domainSplit(samples: samples).isEmpty)
    }

    // MARK: - External work signal

    func testSubtypelessSessionUsesMeasuredMotion() {
        // Most real sessions carry no subtype. A label-only rule disabled
        // Efficiency for nearly all of them.
        let varying: [Float] = [10, 25, 40, 55, 70]
        XCTAssertTrue(ExerciseIntensity.hasExternalWorkSignal(subtype: nil, motion: varying))

        let flat: [Float] = [12, 12.5, 13, 12.8, 12.2]
        XCTAssertFalse(ExerciseIntensity.hasExternalWorkSignal(subtype: nil, motion: flat),
                       "flat motion is no denominator")
    }

    func testMisleadingSubtypeOverridesEvenStrongMotion() {
        // A barbell session moves the chest plenty; none of it tracks the load.
        let varying: [Float] = [10, 30, 60, 90]
        XCTAssertFalse(ExerciseIntensity.hasExternalWorkSignal(subtype: "Power Lifting",
                                                               motion: varying))
        XCTAssertFalse(ExerciseIntensity.hasExternalWorkSignal(subtype: "Yoga", motion: varying))
    }

    func testKnownMotionBearingSubtypeWinsEvenOnThinMotion() {
        XCTAssertTrue(ExerciseIntensity.hasExternalWorkSignal(subtype: "Intervals",
                                                              motion: [20, 21]))
    }

    func testEmptyMotionIsNoSignal() {
        XCTAssertFalse(ExerciseIntensity.hasExternalWorkSignal(subtype: nil, motion: []))
    }

    func testMotionBearingSubtypesAreRecognised() {
        for sub in ["Intervals", "Easy Run", "Nature Walk", "Hiking", "Rowing"] {
            XCTAssertTrue(ExerciseIntensity.motionBearingSubtypes.contains(sub),
                          "\(sub) has motion proportional to work")
        }
    }

    func testLowMotionSubtypesAreExcluded() {
        // Chest motion does not measure barbell work: a heavy single moves less
        // than a light set of ten, so these get no Efficiency denominator.
        for sub in ["Power Lifting", "Yoga", "Cycling", "Swimming"] {
            XCTAssertFalse(ExerciseIntensity.motionBearingSubtypes.contains(sub),
                           "\(sub) must not claim an external work signal")
        }
    }
}
