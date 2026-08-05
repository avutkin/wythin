import XCTest
@testable import Wythin

final class HeartRateRecoveryTests: XCTestCase {

    /// Falls linearly from `from` to `to` across `seconds`.
    private func fall(from: Double, to: Double, seconds: Double,
                      step: Double = 10) -> [(seconds: Double, hr: Double)] {
        stride(from: 0.0, through: seconds, by: step).map {
            (seconds: $0, hr: from + (to - from) * ($0 / seconds))
        }
    }

    // MARK: - HRR60

    func testHRR60IsTheDropAcrossTheFirstMinute() {
        // 160 → 120 over the first 60 s.
        let s = fall(from: 160, to: 100, seconds: 120)
        XCTAssertEqual(HeartRateRecovery.hrr60(after: s, hrAtEnd: 160,
                                               restingHR: 55, peakHR: 165)!,
                       30, accuracy: 0.001)
    }

    func testHRR60InterpolatesBetweenBracketingSamples() {
        // Samples at 30 s and 90 s only — +60 s must be interpolated, not skipped.
        let s: [(seconds: Double, hr: Double)] = [(30, 150), (90, 130)]
        XCTAssertEqual(HeartRateRecovery.hrr60(after: s, hrAtEnd: 160,
                                               restingHR: 55, peakHR: 165)!,
                       20, accuracy: 0.001)
    }

    func testAFasterFallGivesABiggerNumber() {
        let fast = HeartRateRecovery.hrr60(after: fall(from: 160, to: 90, seconds: 60),
                                           hrAtEnd: 160, restingHR: 55, peakHR: 165)!
        let slow = HeartRateRecovery.hrr60(after: fall(from: 160, to: 145, seconds: 60),
                                           hrAtEnd: 160, restingHR: 55, peakHR: 165)!
        XCTAssertGreaterThan(fast, slow)
    }

    func testASessionThatEndedEasyIsNotMeasured() {
        // Ended at 70 against a resting 55 and a peak of 165 — any fall from
        // there is drift, not recovery.
        let s = fall(from: 70, to: 64, seconds: 120)
        XCTAssertNil(HeartRateRecovery.hrr60(after: s, hrAtEnd: 70,
                                             restingHR: 55, peakHR: 165))
    }

    func testARecordingThatStopsWellShortOfSixtySecondsIsNotExtrapolated() {
        let s: [(seconds: Double, hr: Double)] = [(0, 160), (10, 155), (20, 150)]
        XCTAssertNil(HeartRateRecovery.hrr60(after: s, hrAtEnd: 160,
                                             restingHR: 55, peakHR: 165))
    }

    func testARecordingThatStopsJustShortIsStillUsed() {
        let s: [(seconds: Double, hr: Double)] = [(0, 160), (30, 145), (45, 138)]
        XCTAssertNotNil(HeartRateRecovery.hrr60(after: s, hrAtEnd: 160,
                                                restingHR: 55, peakHR: 165))
    }

    func testARisingTraceCannotProduceANegativeDrop() {
        let s: [(seconds: Double, hr: Double)] = [(0, 150), (60, 160)]
        XCTAssertEqual(HeartRateRecovery.hrr60(after: s, hrAtEnd: 150,
                                               restingHR: 55, peakHR: 165)!, 0)
    }

    // MARK: - T30

    func testT30IsPositiveAndSmallerForAFasterFall() {
        let fast = HeartRateRecovery.t30(after: fall(from: 160, to: 120, seconds: 30, step: 5))!
        let slow = HeartRateRecovery.t30(after: fall(from: 160, to: 152, seconds: 30, step: 5))!
        XCTAssertGreaterThan(fast, 0)
        XCTAssertLessThan(fast, slow, "a steeper decay has a shorter time constant")
    }

    func testT30NeedsThreeSamplesInsideThirtySeconds() {
        XCTAssertNil(HeartRateRecovery.t30(after: [(0, 160), (25, 150)]))
    }

    func testAFlatOrRisingTraceHasNoTimeConstant() {
        XCTAssertNil(HeartRateRecovery.t30(after: [(0, 150), (10, 150), (20, 150), (30, 150)]))
        XCTAssertNil(HeartRateRecovery.t30(after: [(0, 150), (10, 152), (20, 155), (30, 158)]))
    }

    func testT30IgnoresSamplesBeyondThirtySeconds() {
        // A long tail must not drag the short-term constant.
        let short = HeartRateRecovery.t30(after: fall(from: 160, to: 130, seconds: 30, step: 5))!
        var withTail = fall(from: 160, to: 130, seconds: 30, step: 5)
        withTail += [(120, 90), (300, 70)]
        XCTAssertEqual(HeartRateRecovery.t30(after: withTail)!, short, accuracy: 0.001)
    }

    // MARK: - It works where the vagal measures cannot

    func testItNeedsNoDCAtAll() {
        // The practical point: lifting sessions often yield no usable DC, so
        // every vagal measure goes blank. Heart rate is always there.
        let s = fall(from: 150, to: 110, seconds: 60)
        XCTAssertNotNil(HeartRateRecovery.hrr60(after: s, hrAtEnd: 150,
                                                restingHR: 60, peakHR: 155))
        XCTAssertNotNil(HeartRateRecovery.t30(after: s))
    }

    // MARK: - Scoring

    func testScoreRisesWithTheDrop() {
        XCTAssertEqual(HeartRateRecovery.score(hrr60: HeartRateRecovery.fastHRR60), 100)
        XCTAssertEqual(HeartRateRecovery.score(hrr60: HeartRateRecovery.slowHRR60), 0)
        XCTAssertEqual(HeartRateRecovery.score(hrr60: 25)!, 50, accuracy: 1)
    }

    func testScoreClampsRatherThanOverflowing() {
        XCTAssertEqual(HeartRateRecovery.score(hrr60: 200), 100)
        XCTAssertEqual(HeartRateRecovery.score(hrr60: 0), 0)
        XCTAssertNil(HeartRateRecovery.score(hrr60: nil))
    }
}
