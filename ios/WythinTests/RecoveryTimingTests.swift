import XCTest
@testable import Wythin

final class RecoveryTimingTests: XCTestCase {

    /// Climbs linearly from `from` to `to` over `minutes`.
    private func ramp(from: Double, to: Double, minutes: Double,
                      step: Double = 0.5) -> [(minutes: Double, dc: Double)] {
        stride(from: 0.0, through: minutes, by: step).map {
            (minutes: $0, dc: from + (to - from) * ($0 / minutes))
        }
    }

    // MARK: - Reaching halfway

    func testTimeToHalfwayIsReported() {
        // Fell to 2 from a resting 8, so the bar is halfway between them: 5.
        // The climb 2 → 6 over ten minutes crosses 5 at 7.5.
        let out = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                              dcPre: 8, dcTrough: 2)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 7.5, accuracy: 0.6)
    }

    func testAFasterRecoveryReportsASmallerTime() {
        // Both must clear the bar of 5; the steeper climb must get there sooner.
        let fast = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 9, minutes: 10),
                                               dcPre: 8, dcTrough: 2)
        let slow = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 5.5, minutes: 10),
                                               dcPre: 8, dcTrough: 2)
        guard case let .reached(f) = fast, case let .reached(s) = slow else {
            return XCTFail("expected both to reach")
        }
        XCTAssertLessThan(f, s)
    }

    // MARK: - The case that started this

    func testVagalToneStillFallingIsNotReportedAsRecovery() {
        // The real session: it descends the whole time. A percentage quoted the
        // level and read as though something had come back. This cannot.
        let falling = ramp(from: 4.6, to: 2.3, minutes: 9)
        let out = RecoveryTiming.halfRecovery(after: falling, dcPre: 8.0, dcTrough: 2.0)
        guard case let .notReached(observed) = out else {
            return XCTFail("a falling trace must never read as reached, got \(out)")
        }
        XCTAssertEqual(observed, 9, accuracy: 0.6)
        XCTAssertEqual(RecoveryTiming.score(out), 0)
    }

    func testATouchThatDoesNotHoldIsNotRecovery() {
        var s = ramp(from: 2, to: 3, minutes: 10)
        s.append((minutes: 4.0, dc: 9.0))   // one spike over the bar
        let out = RecoveryTiming.halfRecovery(after: s, dcPre: 8, dcTrough: 2)
        guard case .notReached = out else { return XCTFail("a single spike is not recovery") }
    }

    // MARK: - Honest absence

    func testTooShortARecordingSaysSoRatherThanScoringZero() {
        let out = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 2.5, minutes: 3), dcPre: 8, dcTrough: 2)
        XCTAssertEqual(out, .notObserved)
        XCTAssertNil(RecoveryTiming.score(out),
                     "three minutes of watching cannot justify a zero")
    }

    func testNoRestingLevelMeansNothingToMeasureAgainst() {
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                                   dcPre: nil, dcTrough: 2), .notObserved)
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                                   dcPre: 0, dcTrough: 2), .notObserved)
    }

    func testEmptyAfterWindow() {
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: [], dcPre: 8, dcTrough: 2), .notObserved)
    }

    func testSamplesBeforeTheEndAreIgnored() {
        var s = ramp(from: 2, to: 6, minutes: 10)
        s.append((minutes: -5, dc: 9))   // still mid-session
        guard case let .reached(m) = RecoveryTiming.halfRecovery(after: s, dcPre: 8, dcTrough: 2) else {
            return XCTFail("expected reached")
        }
        XCTAssertGreaterThan(m, 0)
    }

    // MARK: - Scoring

    func testFastRecoveryScoresTop() {
        XCTAssertEqual(RecoveryTiming.score(.reached(minutes: 2)), 100)
    }

    func testSlowRecoveryScoresBottom() {
        XCTAssertEqual(RecoveryTiming.score(.reached(minutes: 30)), 0)
    }

    func testScoreFallsMonotonicallyWithTime() {
        let scores = [3.0, 8.0, 14.0, 20.0, 25.0].map { RecoveryTiming.score(.reached(minutes: $0))! }
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    // MARK: - Copy

    func testSummaryNeverClaimsRecoveryThatDidNotHappen() {
        let s = RecoveryTiming.summary(.notReached(observedMinutes: 9)).lowercased()
        XCTAssertTrue(s.contains("less than halfway"))
        XCTAssertFalse(s.contains("back to your resting level "))
    }
}

// MARK: - The bar is measured from the fall, not from resting

extension RecoveryTimingTests {

    func testTheTargetIsHalfwayFromTroughToResting() {
        // Fell 8 → 2, so halfway back is 5 — not 4, which is half of resting.
        XCTAssertEqual(RecoveryTiming.targetLevel(dcPre: 8, dcTrough: 2), 5, accuracy: 0.001)
    }

    func testAMildSessionIsNotInstantlyRecovered() {
        // The bug this replaces: vagal tone dipped only to 6 of a resting 8, so
        // half of resting (4) sat below the trough and was met at minute zero —
        // "halfway back in 0 minutes" for a session that had barely dipped.
        let flat: [(minutes: Double, dc: Double)] =
            stride(from: 0.0, through: 10.0, by: 0.5).map { ($0, 6.0) }
        let out = RecoveryTiming.halfRecovery(after: flat, dcPre: 8, dcTrough: 6)
        guard case .notReached = out else {
            return XCTFail("a trace that never climbs must not read as recovered, got \(out)")
        }
    }

    func testADeepSessionUsesADeeperBar() {
        // Fell to 1 of a resting 9, so the bar is 5. Reaching 4 is not halfway.
        let climb: [(minutes: Double, dc: Double)] =
            stride(from: 0.0, through: 10.0, by: 0.5).map { ($0, 1.0 + 3.0 * ($0 / 10)) }
        guard case .notReached = RecoveryTiming.halfRecovery(after: climb, dcPre: 9, dcTrough: 1) else {
            return XCTFail("topping out at 4 is short of the halfway bar of 5")
        }
    }

    func testNoSuppressionMeansNothingToRecoverFrom() {
        let flat: [(minutes: Double, dc: Double)] = [(0, 8), (5, 8), (10, 8)]
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: flat, dcPre: 8, dcTrough: 8), .notObserved)
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: flat, dcPre: 8, dcTrough: nil), .notObserved)
    }

    // MARK: - The hold window is bounded

    func testADipLongAfterRecoveryDoesNotUndoIt() {
        // The photographed session. Vagal tone is back at minute 4 and holds
        // for the rest of the hour bar one sag at minute 20.
        //
        // The hold used to be tested against EVERY remaining sample, over a
        // four-hour fetch window, so this scored zero while the same screen
        // said "back within 10% of your resting level 4 minutes after you
        // stopped". Recovery that already happened cannot be undone by a dip
        // half an hour later — and the old rule meant the longer you wore the
        // strap, the more certainly it reported failure.
        var after = ramp(from: 20, to: 62, minutes: 4)
        after += stride(from: 4.5, through: 19.5, by: 0.5).map { ($0, 95.0) }
        after.append((20.0, 52))
        after += stride(from: 20.5, through: 34.0, by: 0.5).map { ($0, 96.0) }

        let out = RecoveryTiming.halfRecovery(after: after, dcPre: 100, dcTrough: 20)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 4, accuracy: 1)
        XCTAssertGreaterThan(RecoveryTiming.score(out) ?? 0, 80)
    }

    func testADipInsideTheHoldWindowStillDisqualifies() {
        // The guard: a touch that immediately falls away is not recovery, and
        // that is the whole reason a hold exists. Crossing at 4, collapsing at
        // 5, is inside the confirmation window and must not count.
        var after = ramp(from: 20, to: 62, minutes: 4)
        after += stride(from: 4.5, through: 34.0, by: 0.5).map { ($0, 30.0) }

        let out = RecoveryTiming.halfRecovery(after: after, dcPre: 100, dcTrough: 20)
        XCTAssertEqual(out, .notReached(observedMinutes: 34),
                       "a crossing that collapses within the hold window is not recovery")
    }

    func testALaterGenuineRecoveryIsFoundAfterAFailedCrossing() {
        // A brief touch at 3 that collapses, then a real return at 20. The
        // first crossing failing must not abandon the search — the session did
        // recover, just later than its first flicker.
        var after = ramp(from: 20, to: 62, minutes: 3)
        after += stride(from: 3.5, through: 19.5, by: 0.5).map { ($0, 30.0) }
        after += stride(from: 20.0, through: 40.0, by: 0.5).map { ($0, 95.0) }

        let out = RecoveryTiming.halfRecovery(after: after, dcPre: 100, dcTrough: 20)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 20, accuracy: 1)
    }

    func testARecordingThatEndsInsideTheHoldWindowStillCounts() {
        // Recovery at 4 with the strap coming off at 6: only two minutes of
        // confirmation exist. Demanding a full five would report failure for a
        // session that plainly recovered, so what is there must hold.
        var after = ramp(from: 20, to: 62, minutes: 4)
        after += stride(from: 4.5, through: 6.0, by: 0.5).map { ($0, 95.0) }

        let out = RecoveryTiming.halfRecovery(after: after, dcPre: 100, dcTrough: 20)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 4, accuracy: 1)
    }
}
