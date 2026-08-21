import XCTest
@testable import Wythin

final class RecoveryProfileTests: XCTestCase {

    /// Heart rate falling from a peak toward resting while the brake climbs out
    /// of its trough — one sample every half minute.
    private func series(minutes: Double,
                        hrFrom: Double, hrTo: Double,
                        dcFrom: Double, dcTo: Double) -> [RecoveryProfile.Sample] {
        stride(from: 0.0, through: minutes, by: 0.5).map { m in
            let t = m / minutes
            return .init(minutes: m,
                         hr: hrFrom + (hrTo - hrFrom) * t,
                         dc: dcFrom + (dcTo - dcFrom) * t)
        }
    }

    /// Recovery decays toward its target rather than sliding to it linearly —
    /// fast at first, then flattening. `tau` is the time constant in minutes:
    /// small for heart rate, large for the vagal brake.
    private func decay(minutes: Double,
                       hrFrom: Double, hrTo: Double, hrTau: Double,
                       dcFrom: Double, dcTo: Double, dcTau: Double) -> [RecoveryProfile.Sample] {
        stride(from: 0.0, through: minutes, by: 0.5).map { m in
            .init(minutes: m,
                  hr: hrTo + (hrFrom - hrTo) * exp(-m / hrTau),
                  dc: dcTo + (dcFrom - dcTo) * exp(-m / dcTau))
        }
    }

    // MARK: - The two layers move independently

    /// The state the section exists to show: heart rate home, regulation not.
    /// The two percentages must disagree, because the two processes did.
    func testHeartRateHomeWithVagalStillDownReadsAsTwoDifferentNumbers() {
        // Heart rate settles with a three-minute time constant against a
        // resting 60; the brake crawls back with a forty-minute one, so at the
        // ten-minute checkpoint it is barely out of its hole.
        let s = decay(minutes: 20,
                      hrFrom: 170, hrTo: 62, hrTau: 3,
                      dcFrom: 2, dcTo: 8, dcTau: 40)
        let out = RecoveryProfile.build(after: s, restingHR: 60, peakHR: 170,
                                        dcPre: 8, dcTrough: 2)
        guard let cardio = out.cardiovascular, let neural = out.neural else {
            return XCTFail("both layers should read")
        }
        XCTAssertGreaterThan(cardio, 70, "heart rate was most of the way back")
        XCTAssertLessThan(neural, 30, "the brake was not")
        XCTAssertGreaterThan(cardio - neural, 40, "the divergence is the finding")
    }

    /// Physical recovery is not visible to an ECG, and the model must keep
    /// saying so rather than letting the other two stand in for readiness.
    func testPhysicalRecoveryIsNeverReported() {
        let s = series(minutes: 20, hrFrom: 170, hrTo: 61, dcFrom: 2, dcTo: 8)
        let out = RecoveryProfile.build(after: s, restingHR: 60, peakHR: 170,
                                        dcPre: 8, dcTrough: 2)
        XCTAssertNil(out.physical)
    }

    // MARK: - Time to stable

    func testBothChannelsHomeReportsATime() {
        // Both are home well before the end, and stay.
        let s = series(minutes: 30, hrFrom: 170, hrTo: 61, dcFrom: 2, dcTo: 9)
        let out = RecoveryProfile.timeToStable(s, restingHR: 60, dcPre: 8, dcTrough: 2)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertGreaterThan(m, 0)
        XCTAssertLessThan(m, 30)
    }

    /// The common hard-session case, and the one the display has to handle
    /// well: heart rate home, the brake never halfway, so the pair never lands.
    func testOneChannelShortMeansTheTimeIsABoundNotANumber() {
        let s = series(minutes: 34, hrFrom: 170, hrTo: 61, dcFrom: 2, dcTo: 2.6)
        let out = RecoveryProfile.timeToStable(s, restingHR: 60, dcPre: 8, dcTrough: 2)
        guard case let .notReached(observed) = out else {
            return XCTFail("expected a bound, got \(out)")
        }
        XCTAssertEqual(observed, 34, accuracy: 0.6)
    }

    /// Both channels are needed. Heart rate alone can never call it stable —
    /// that is the whole point of the pair.
    func testHeartRateAloneDoesNotMakeItStable() {
        let s = stride(from: 0.0, through: 20.0, by: 0.5).map {
            RecoveryProfile.Sample(minutes: $0, hr: 61, dc: nil)
        }
        let out = RecoveryProfile.timeToStable(s, restingHR: 60, dcPre: 8, dcTrough: 2)
        XCTAssertNotEqual(out, .reached(minutes: 0))
    }

    func testTooShortARecordingSaysSoRatherThanClaimingFailure() {
        let s = series(minutes: 3, hrFrom: 170, hrTo: 140, dcFrom: 2, dcTo: 2.2)
        let out = RecoveryProfile.timeToStable(s, restingHR: 60, dcPre: 8, dcTrough: 2)
        XCTAssertEqual(out, .notObserved)
    }

    // MARK: - Stability

    /// Two sessions with the same halfway time, one settled and one bouncing.
    /// The halfway time cannot tell them apart — both cross once — so stability
    /// is what carries the difference.
    func testABouncingReturnScoresLowerThanASettledOne() {
        let settled = series(minutes: 20, hrFrom: 170, hrTo: 61, dcFrom: 2, dcTo: 8)
        var bouncing = settled
        for i in stride(from: 12, to: bouncing.count, by: 4) {
            bouncing[i] = .init(minutes: bouncing[i].minutes,
                                hr: (bouncing[i].hr ?? 0) + 34,
                                dc: (bouncing[i].dc ?? 0) * 0.55)
        }
        guard let calm = RecoveryProfile.stabilityPercent(settled),
              let jumpy = RecoveryProfile.stabilityPercent(bouncing) else {
            return XCTFail("both should score")
        }
        XCTAssertGreaterThan(calm, jumpy)
    }

    // MARK: - Absence

    func testNoReferenceLevelsMeansNoPercentages() {
        let s = series(minutes: 20, hrFrom: 170, hrTo: 61, dcFrom: 2, dcTo: 8)
        let out = RecoveryProfile.build(after: s, restingHR: nil, peakHR: nil,
                                        dcPre: nil, dcTrough: nil)
        XCTAssertNil(out.cardiovascular)
        XCTAssertNil(out.neural)
        XCTAssertEqual(out.timeToStable, .notObserved)
    }

    /// A recording that stops before the ten-minute mark has no profile
    /// reading, rather than one taken from whatever sample happens to be last.
    func testAShortRecordingHasNoTenMinuteReading() {
        let s = series(minutes: 4, hrFrom: 170, hrTo: 80, dcFrom: 2, dcTo: 5)
        let out = RecoveryProfile.build(after: s, restingHR: 60, peakHR: 170,
                                        dcPre: 8, dcTrough: 2)
        XCTAssertNil(out.cardiovascular)
        XCTAssertNil(out.neural)
    }

    // MARK: - Expectation bands

    func testTheBandIsTheDomainTheSessionSpentMostTimeIn() {
        XCTAssertEqual(RecoveryExpectation.band(moderateSec: 900, heavySec: 200, severeSec: 0),
                       .moderate)
        XCTAssertEqual(RecoveryExpectation.band(moderateSec: 200, heavySec: 900, severeSec: 100),
                       .heavy)
        XCTAssertEqual(RecoveryExpectation.band(moderateSec: 100, heavySec: 200, severeSec: 900),
                       .severe)
        XCTAssertNil(RecoveryExpectation.band(moderateSec: 0, heavySec: 0, severeSec: 0))
    }

    /// The sentence a bound is shown against. Without it, ">34 min" reads as a
    /// failure rather than as an ordinary heavy session.
    func testAHeavySessionExpectsALongRebound() {
        let sentence = RecoveryExpectation.sentence(for: .heavy)
        XCTAssertTrue(sentence.contains("15–45"), sentence)
        XCTAssertTrue(sentence.contains("heavy"), sentence)
    }
}
