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

    func testCrossingCountsEvenIfItEasesBackAfterwards() {
        // The photographed treadmill session. The vagal brake climbed out of
        // its hole, crossed the halfway bar at about twelve minutes, peaked,
        // and then eased off a little — and the section reported ">19 min ·
        // still recalibrating", directly above a chart showing the trace
        // plainly above the line it was said not to have reached.
        //
        // A five-minute hold asks the signal to cross AND STAY, which is a
        // stricter question than the one being reported. Post-exercise vagal
        // tone oscillates on exactly that scale, and every standard index of
        // this shape — HRR60, T30, half-recovery time — is read at a moment.
        var trace: [(minutes: Double, dc: Double)] = []
        for i in 0...24 {                       // 0 → 12 min, climbing to the bar
            trace.append((minutes: Double(i) * 0.5, dc: 1.3 + Double(i) * 0.19))
        }
        for i in 1...10 {                       // then easing back
            trace.append((minutes: 12 + Double(i) * 0.5, dc: 5.85 - Double(i) * 0.06))
        }
        let out = RecoveryTiming.halfRecovery(after: trace, dcPre: 10.1, dcTrough: 1.3)
        guard case let .reached(minutes) = out else {
            return XCTFail("crossed the bar at ~12 min; got \(out)")
        }
        XCTAssertEqual(minutes, 12, accuracy: 2)
        XCTAssertGreaterThan(RecoveryTiming.score(out) ?? 0, 40,
                             "a crossing at twelve minutes is a real recovery, not a 3")
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

// MARK: - The excursion has to clear the noise before it can be scored

/// The photographed yoga session. Its vagal brake went from 14.6 ms resting to
/// a 14.4 ms trough — a 1.4 % dip, less than the measurement's own scatter —
/// and the halfway bar landed at 14.5 ms, which the first sample after the
/// session was already above. The card printed `0.2 min to halfway` and scored
/// the session **100 / 100 · recovery**, above a chart whose "during" line had
/// gone *up*.
extension RecoveryTimingTests {

    private func flatAfter(_ level: Double,
                           minutes: Double = 12) -> [(minutes: Double, dc: Double)] {
        stride(from: 0.0, through: minutes, by: 0.5).map { ($0, level) }
    }

    func testANoiseSizedDipIsNotAPerfectRecovery() {
        let out = RecoveryTiming.halfRecovery(after: flatAfter(14.6),
                                              dcPre: 14.6, dcTrough: 14.4)
        XCTAssertEqual(out, .notObserved,
                       "a 1.4 % dip is not a hole to climb out of, got \(out)")
        XCTAssertNil(RecoveryTiming.score(out),
                     "an unscorable excursion must leave the checkpoint absent, never 100")
    }

    func testTheOldRuleWouldHaveScoredThatSessionOneHundred() {
        // Pins what changed: the crossing rule itself still says "instantly",
        // so the fix has to be the bar's existence, not the crossing.
        let bar = RecoveryTiming.targetLevel(dcPre: 14.6, dcTrough: 14.4)
        let out = RecoveryTiming.crossing(
            flatAfter(14.6).map { (minutes: $0.minutes, value: $0.dc) },
            target: bar, direction: .upward)
        XCTAssertEqual(RecoveryTiming.score(out), 100,
                       "precondition: without the floor this session scores full marks")
    }

    func testTheFloorSitsExactlyWhereItIsDocumented() {
        let up = RecoveryTiming.Direction.upward
        // Ten per cent of a resting 10 is a trough of 9.
        XCTAssertNotNil(up.target(pre: 10, extreme: 9.0), "exactly a tenth is scorable")
        XCTAssertNil(up.target(pre: 10, extreme: 9.05), "just under a tenth is not")
        XCTAssertEqual(RecoveryTiming.minimumDrawdownFraction, 0.10, accuracy: 0.0001)
    }

    func testABrakeThatROSEDuringTheSessionHasNoRebound() {
        // Exactly the photographed chart: the "during" line above resting.
        let up = RecoveryTiming.Direction.upward
        XCTAssertNil(up.target(pre: 14.6, extreme: 20.8))
        XCTAssertEqual(up.drawdownFraction(pre: 14.6, extreme: 20.8)!, -0.4247, accuracy: 0.001,
                       "a rise is a negative drawdown, not a small one")
    }

    func testTheSameFloorAppliesToHeartRate() {
        let down = RecoveryTiming.Direction.downward
        XCTAssertNil(down.target(pre: 60, extreme: 63), "three beats is not an excursion")
        XCTAssertNotNil(down.target(pre: 60, extreme: 66), "ten per cent is")
        // Any session that reaches the exercise screen at all clears this: the
        // activation threshold is a 15 bpm rise in the MEAN, and the peak is
        // higher still.
        XCTAssertNotNil(down.target(pre: 60, extreme: 60 + ActivityClass.activatingHRRise))
    }

    func testADeepSessionIsUnaffectedByTheFloor() {
        // Everything this analysis exists for falls far further than a tenth.
        let out = RecoveryTiming.halfRecovery(after: ramp(from: 2, to: 6, minutes: 10),
                                              dcPre: 8, dcTrough: 2)
        guard case .reached = out else { return XCTFail("expected reached, got \(out)") }
    }

    func testTheDrawdownFractionIsAShareOfResting() {
        let up = RecoveryTiming.Direction.upward
        XCTAssertEqual(up.drawdownFraction(pre: 8, extreme: 2)!, 0.75, accuracy: 0.0001)
        XCTAssertNil(up.drawdownFraction(pre: 0, extreme: 2), "no resting level, no share of it")
    }

    /// The floor must reach every consumer through the one function, or the
    /// card goes back to disagreeing with itself: a dashed bar drawn where no
    /// bar is scored, or a neural percentage built from a denominator of noise.
    func testTheProfilePercentagesFallSilentTogether() {
        let after = (0...24).map {
            RecoveryProfile.Sample(minutes: Double($0) * 0.5, hr: 61, dc: 14.5)
        }
        let out = RecoveryProfile.build(after: after,
                                        restingHR: 60, peakHR: 62,
                                        dcPre: 14.6, dcTrough: 14.4)
        XCTAssertNil(out.neural, "a 1.4 % dip has no share of itself to have climbed back")
        XCTAssertNil(out.cardiovascular, "nor does a two-beat rise")
        XCTAssertEqual(out.timeToStable, .notObserved)
    }

    func testTheProfileStillReadsARealSession() {
        let after = (0...24).map {
            RecoveryProfile.Sample(minutes: Double($0) * 0.5, hr: 70, dc: 5)
        }
        let out = RecoveryProfile.build(after: after,
                                        restingHR: 60, peakHR: 170,
                                        dcPre: 8, dcTrough: 2)
        XCTAssertNotNil(out.neural)
        XCTAssertNotNil(out.cardiovascular)
    }

    // MARK: - Back to resting

    /// The curve is drawn to the moment the signal is back inside a tenth of
    /// its resting level, and the card reports that moment — not the halfway
    /// mark the score is built from.
    func testReturnToRestingIsTimedAtTheRestingBand() {
        // Resting 8, so home is 7.2. The climb 2 → 9 over ten minutes crosses
        // 7.2 at 7.43.
        let out = RecoveryTiming.returnToResting(ramp(from: 2, to: 9, minutes: 10).map {
            (minutes: $0.minutes, value: $0.dc)
        }, pre: 8, extreme: 2, direction: .upward)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 7.43, accuracy: 0.6)
        XCTAssertEqual(RecoveryTiming.Direction.upward.homeTarget(pre: 8), 7.2, accuracy: 0.0001)
    }

    func testReturnToRestingStopsShortWhenOnlyHalfwayCameBack() {
        // Clears the halfway bar of 5 comfortably; never reaches 7.2.
        let out = RecoveryTiming.returnToResting(ramp(from: 2, to: 6, minutes: 10).map {
            (minutes: $0.minutes, value: $0.dc)
        }, pre: 8, extreme: 2, direction: .upward)
        guard case let .notReached(observed) = out else {
            return XCTFail("expected notReached, got \(out)")
        }
        XCTAssertEqual(observed, 10, accuracy: 0.6)
    }

    func testReturnToRestingNeedsAnExcursion() {
        // The same floor as the halfway bar: a brake that barely dipped has
        // nothing to return from, and that is not a gap in the recording.
        let flat = (0...24).map { (minutes: Double($0) * 0.5, value: 7.9) }
        XCTAssertEqual(RecoveryTiming.returnToResting(flat, pre: 8, extreme: 7.8,
                                                      direction: .upward), .notObserved)
    }

    func testHeartRateReturnsToRestingFromAbove() {
        // Resting 60, so home is 66. The fall 150 → 60 over ten minutes
        // crosses 66 at 9.33.
        let fall = stride(from: 0.0, through: 10, by: 0.5).map {
            (minutes: $0, value: 150 - 90 * ($0 / 10))
        }
        let out = RecoveryTiming.returnToResting(fall, pre: 60, extreme: 150, direction: .downward)
        guard case let .reached(m) = out else { return XCTFail("expected reached, got \(out)") }
        XCTAssertEqual(m, 9.33, accuracy: 0.6)
        XCTAssertEqual(RecoveryTiming.Direction.downward.homeTarget(pre: 60), 66, accuracy: 0.0001)
    }

    /// The profile's "home" band for heart rate is the same band the curve
    /// ends at, so the two cannot drift apart.
    func testTheProfileHomeBandIsTheChartHomeBand() {
        XCTAssertEqual(RecoveryProfile.restingTolerance,
                       1 + RecoveryTiming.homeTolerance, accuracy: 0.0001)
    }

    // MARK: - Where the curve stops

    func testTheCurveEndsShortlyAfterTheReturn() {
        // Heart rate home four minutes after a thirty-minute session, with
        // three hours of recording behind it: the chart stops a couple of
        // minutes past the landing, not at the end of the recording.
        let end = RecoveryCurveChart.visibleEnd(sessionMinutes: 30,
                                                returned: .reached(minutes: 4),
                                                lastAfter: 180)
        XCTAssertEqual(end, 36, accuracy: 0.01)
    }

    func testTheCurveMarginScalesWithASlowReturn() {
        // A brake home at forty minutes gets a quarter again so the landing
        // is visible as a landing rather than an edge.
        let end = RecoveryCurveChart.visibleEnd(sessionMinutes: 30,
                                                returned: .reached(minutes: 40),
                                                lastAfter: 180)
        XCTAssertEqual(end, 80, accuracy: 0.01)
    }

    func testTheCurveNeverRunsPastTheRecording() {
        let end = RecoveryCurveChart.visibleEnd(sessionMinutes: 30,
                                                returned: .reached(minutes: 9),
                                                lastAfter: 10)
        XCTAssertEqual(end, 40, accuracy: 0.01)
    }

    func testTheCurveRunsToTheEndWhenItNeverGotHome() {
        XCTAssertEqual(RecoveryCurveChart.visibleEnd(sessionMinutes: 30,
                                                     returned: .notReached(observedMinutes: 180),
                                                     lastAfter: 180), 210, accuracy: 0.01)
        XCTAssertEqual(RecoveryCurveChart.visibleEnd(sessionMinutes: 30,
                                                     returned: .notObserved,
                                                     lastAfter: 5), 35, accuracy: 0.01)
    }
}
