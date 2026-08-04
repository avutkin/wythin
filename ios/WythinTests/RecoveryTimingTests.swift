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
        // Resting 8, so the bar is 4. Climbs 2 → 6 over 10 min, crossing 4 at 5.
        let out = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                              dcPre: 8)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 5, accuracy: 0.6)
    }

    func testAFasterRecoveryReportsASmallerTime() {
        let fast = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 8, minutes: 10), dcPre: 8)
        let slow = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 4.2, minutes: 10), dcPre: 8)
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
        let out = RecoveryTiming.halfRecovery(after: falling, dcPre: 8.0)
        guard case let .notReached(observed) = out else {
            return XCTFail("a falling trace must never read as reached, got \(out)")
        }
        XCTAssertEqual(observed, 9, accuracy: 0.6)
        XCTAssertEqual(RecoveryTiming.score(out), 0)
    }

    func testATouchThatDoesNotHoldIsNotRecovery() {
        var s = ramp(from: 2, to: 3, minutes: 10)
        s.append((minutes: 4.0, dc: 9.0))   // one spike over the bar
        let out = RecoveryTiming.halfRecovery(after: s, dcPre: 8)
        guard case .notReached = out else { return XCTFail("a single spike is not recovery") }
    }

    // MARK: - Honest absence

    func testTooShortARecordingSaysSoRatherThanScoringZero() {
        let out = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 2.5, minutes: 3), dcPre: 8)
        XCTAssertEqual(out, .notObserved)
        XCTAssertNil(RecoveryTiming.score(out),
                     "three minutes of watching cannot justify a zero")
    }

    func testNoRestingLevelMeansNothingToMeasureAgainst() {
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                                   dcPre: nil), .notObserved)
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                                   dcPre: 0), .notObserved)
    }

    func testEmptyAfterWindow() {
        XCTAssertEqual(RecoveryTiming.halfRecovery(after: [], dcPre: 8), .notObserved)
    }

    func testSamplesBeforeTheEndAreIgnored() {
        var s = ramp(from: 2, to: 6, minutes: 10)
        s.append((minutes: -5, dc: 9))   // still mid-session
        guard case let .reached(m) = RecoveryTiming.halfRecovery(after: s, dcPre: 8) else {
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
