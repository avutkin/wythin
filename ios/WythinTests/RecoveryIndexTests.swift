import XCTest
@testable import Wythin

/// The recovery section is a composite, and these pin the two properties whose
/// absence let the old single-measure version print 0 above a chart showing a
/// fast return: no lone checkpoint can be the whole score, and a checkpoint
/// that never arrived is absent rather than zero.
final class RecoveryIndexTests: XCTestCase {

    private var total: Int { RecoveryIndex.weights.count }

    // MARK: - The zero that started this

    /// The recorded pickleball session: the vagal brake never came halfway
    /// back inside the recording, which scores zero on that checkpoint — and
    /// nothing else had landed. One checkpoint is not a section.
    func testALoneCheckpointDoesNotBecomeTheScore() {
        let out = RecoveryIndex.compose(
            hrr60: nil, t30Seconds: nil, t30Peers: [],
            rmssdBefore: nil, rmssdAfter: nil,
            vagal: .notReached(observedMinutes: 34),
            heartRate: .notObserved)
        XCTAssertNil(out, "a lone zero was allowed to stand as the recovery score")
    }

    /// The same session once heart rate is read too. Heart rate was home in
    /// four minutes; the brake was not. The section must land between them,
    /// and nowhere near zero.
    func testASlowBrakeAndAFastHeartRateLandBetween() {
        guard let out = RecoveryIndex.compose(
                hrr60: nil, t30Seconds: nil, t30Peers: [],
                rmssdBefore: nil, rmssdAfter: nil,
                vagal: .notReached(observedMinutes: 34),
                heartRate: .reached(minutes: 4)) else {
            return XCTFail("two checkpoints landed; expected a score")
        }
        XCTAssertGreaterThan(out.value, 20, "a fast heart-rate return counted for nothing")
        XCTAssertLessThan(out.value, 70, "a brake still down at 34 minutes counted for nothing")
        XCTAssertEqual(out.components.count, 2)
    }

    // MARK: - Renormalisation

    /// Missing checkpoints must not drag the mean down: two present at full
    /// marks is 100, not 100 scaled by how many are absent.
    func testMissingCheckpointsAreAbsentNotZero() {
        guard let out = RecoveryIndex.compose(
                hrr60: 40, t30Seconds: nil, t30Peers: [],
                rmssdBefore: 40, rmssdAfter: 40,
                vagal: .notObserved,
                heartRate: .notObserved) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(out.value, 100, "renormalisation is not happening")
    }

    func testEveryCheckpointPresentIsSettled() {
        guard let out = RecoveryIndex.compose(
                hrr60: 30, t30Seconds: 180, t30Peers: [140, 160, 200, 220, 240],
                rmssdBefore: 40, rmssdAfter: 30,
                vagal: .reached(minutes: 8),
                heartRate: .reached(minutes: 5)) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(out.firmness, .settled)
        XCTAssertEqual(out.components.count, total)
    }

    func testAMajorityPresentIsFirming() {
        guard let out = RecoveryIndex.compose(
                hrr60: 30, t30Seconds: nil, t30Peers: [],
                rmssdBefore: 40, rmssdAfter: 30,
                vagal: .reached(minutes: 8),
                heartRate: .notObserved) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(out.firmness, .firming)
    }

    func testTheMinimumIsProvisionalAndSaysHowMany() {
        guard let out = RecoveryIndex.compose(
                hrr60: 30, t30Seconds: nil, t30Peers: [],
                rmssdBefore: nil, rmssdAfter: nil,
                vagal: .reached(minutes: 8),
                heartRate: .notObserved) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(out.firmness, .provisional(present: 2, total: total))
    }

    // MARK: - RMSSD reactivation

    func testFullRMSSDReturnScoresTop() {
        XCTAssertEqual(RecoveryIndex.rmssdReactivationScore(before: 44, after: 44), 100)
    }

    func testDeeplySuppressedRMSSDScoresBottom() {
        XCTAssertEqual(RecoveryIndex.rmssdReactivationScore(before: 44, after: 11), 0)
    }

    func testPartialRMSSDReturnScoresBetween() {
        guard let mid = RecoveryIndex.rmssdReactivationScore(before: 40, after: 25) else {
            return XCTFail("expected a score")
        }
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 100)
    }

    /// Reactivation past the pre-session level is complete, not extra credit.
    func testOvershootIsCappedAtComplete() {
        XCTAssertEqual(RecoveryIndex.rmssdReactivationScore(before: 40, after: 90), 100)
    }

    func testNoBaselineMeansNoReactivationScore() {
        XCTAssertNil(RecoveryIndex.rmssdReactivationScore(before: 0, after: 30))
        XCTAssertNil(RecoveryIndex.rmssdReactivationScore(before: nil, after: 30))
        XCTAssertNil(RecoveryIndex.rmssdReactivationScore(before: 40, after: nil))
    }

    // MARK: - T30 is ranked, never anchored

    /// T30 has no published range this app can defend, so it is scored against
    /// the person's own history or not at all — never against a number we made
    /// up. Below the peer floor it must drop out rather than guess.
    func testT30WithoutEnoughHistoryIsAbsent() {
        XCTAssertNil(RecoveryIndex.t30Score(180, peers: [150, 200]))
    }

    func testAFasterT30ThanUsualScoresAboveASlowerOne() {
        let peers: [Double] = [140, 170, 200, 230, 260]
        guard let fast = RecoveryIndex.t30Score(140, peers: peers),
              let slow = RecoveryIndex.t30Score(260, peers: peers) else {
            return XCTFail("expected scores")
        }
        XCTAssertGreaterThan(fast, slow, "a shorter time constant is faster reactivation")
    }

    // MARK: - Weights

    func testWeightsSumToOne() {
        XCTAssertEqual(RecoveryIndex.weights.values.reduce(0, +), 1.0, accuracy: 0.0001)
    }

    /// Heart rate and the vagal brake ask the same question of two signals that
    /// answer at different speeds. The gap between them is the finding, so
    /// neither may outweigh the other.
    func testTheTwoTimingChannelsAreWeightedEqually() {
        XCTAssertEqual(RecoveryIndex.weights[.vagalRebound],
                       RecoveryIndex.weights[.heartRateReturn])
    }
}
