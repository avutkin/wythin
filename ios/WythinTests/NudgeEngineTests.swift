import XCTest
@testable import Wythin

/// Duration state and suppression — the two pieces the engine keeps outside the
/// metric window.
final class NudgeEngineTests: XCTestCase {

    private let now = Date()

    // MARK: - Durations

    func testStillnessStartsWhenTheUserSettles() {
        var d = NudgeDurations()
        d.ingest(motion: 4, now: now)
        XCTAssertEqual(d.stillSince, now)
    }

    func testStillnessAnchorsToTheFirstStillTickNotTheLatest() {
        var d = NudgeDurations()
        d.ingest(motion: 4, now: now)
        d.ingest(motion: 4, now: now.addingTimeInterval(600))
        XCTAssertEqual(d.stillSince, now)
    }

    func testMovementClearsStillness() {
        var d = NudgeDurations()
        d.ingest(motion: 4, now: now)
        d.ingest(motion: 40, now: now.addingTimeInterval(60))
        XCTAssertNil(d.stillSince)
    }

    /// A brief stretch is not exertion — the lockout should not trip on it.
    func testABriefBurstDoesNotCountAsExertion() {
        var d = NudgeDurations()
        d.ingest(motion: 80, now: now)
        d.ingest(motion: 80, now: now.addingTimeInterval(60))
        XCTAssertNil(d.lastActiveAt)
    }

    func testSustainedHighMotionMarksExertion() {
        var d = NudgeDurations()
        d.ingest(motion: 80, now: now)
        d.ingest(motion: 80, now: now.addingTimeInterval(200))
        XCTAssertNotNil(d.lastActiveAt)
    }

    func testExertionResetsWhenMovementStops() {
        var d = NudgeDurations()
        d.ingest(motion: 80, now: now)
        d.ingest(motion: 4,  now: now.addingTimeInterval(60))
        d.ingest(motion: 80, now: now.addingTimeInterval(120))
        d.ingest(motion: 80, now: now.addingTimeInterval(200))   // only 80s of the new run
        XCTAssertNil(d.lastActiveAt)
    }

    func testLoadStretchAccumulatesAcrossTicks() {
        var d = NudgeDurations()
        d.ingest(motion: 4, now: now)
        d.ingest(motion: 4, now: now.addingTimeInterval(3600))
        XCTAssertEqual(d.loadSince, now)
    }

    func testAnInterruptionResetsEveryStretch() {
        var d = NudgeDurations()
        d.ingest(motion: 4, now: now)
        d.interrupt()
        XCTAssertNil(d.stillSince)
        XCTAssertNil(d.loadSince)
    }

    /// An interruption must not erase the exertion timestamp — the lockout is
    /// precisely what should survive the activity that caused it.
    func testAnInterruptionPreservesTheExertionTimestamp() {
        var d = NudgeDurations()
        d.ingest(motion: 80, now: now)
        d.ingest(motion: 80, now: now.addingTimeInterval(200))
        let marked = d.lastActiveAt
        d.interrupt()
        XCTAssertEqual(d.lastActiveAt, marked)
    }

    // MARK: - Suppression

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: hour))!
    }

    private func reason(standby: Bool = false,
                        activity: Bool = false,
                        baseline: AnchorBaseline? = nil,
                        signals: NudgeSignals? = nil,
                        ledger: NudgeLedger = NudgeLedger(),
                        hour: Int = 10) -> NudgeSuppressionReason? {
        NudgeSuppression.evaluate(now: at(hour),
                                  bleStandby: standby,
                                  activityInProgress: activity,
                                  baseline: baseline ?? NudgeFixture.baseline(),
                                  signals: signals ?? NudgeFixture.signals(now: at(hour)),
                                  ledger: ledger,
                                  calendar: utc)
    }

    func testNothingSuppressesAnOrdinaryDaytimeEvaluation() {
        XCTAssertNil(reason())
    }

    func testStandbySuppresses() {
        XCTAssertEqual(reason(standby: true), .strapOff)
    }

    func testAnActivityInProgressSuppresses() {
        XCTAssertEqual(reason(activity: true), .activityInProgress)
    }

    func testNoBaselineSuppresses() {
        let r = NudgeSuppression.evaluate(now: at(10), bleStandby: false,
                                          activityInProgress: false,
                                          baseline: nil,
                                          signals: NudgeFixture.signals(now: at(10)),
                                          ledger: NudgeLedger(), calendar: utc)
        XCTAssertEqual(r, .noBaseline)
    }

    /// The buffer is not persisted, so every cold launch costs a warm-up.
    func testWarmUpSuppresses() {
        let r = NudgeSuppression.evaluate(now: at(10), bleStandby: false,
                                          activityInProgress: false,
                                          baseline: NudgeFixture.baseline(),
                                          signals: nil,
                                          ledger: NudgeLedger(), calendar: utc)
        XCTAssertEqual(r, .warmingUp)
    }

    func testQuietHoursSuppress() {
        XCTAssertEqual(reason(hour: 23), .quietHours)
    }

    private func spentLedger() -> NudgeLedger {
        var ledger = NudgeLedger()
        ledger = ledger.recording(.vagalWithdrawal, at: at(8),  calendar: utc)
        ledger = ledger.recording(.sustainedLoad,   at: at(11), calendar: utc)
        ledger = ledger.recording(.stuckStill,      at: at(14), calendar: utc)
        return ledger
    }

    /// The downshift cap alone is not full suppression: the focus window is
    /// silent, keeps its own allowance, and is still worth evaluating.
    func testTheDownshiftCapAloneDoesNotSuppressEvaluation() {
        XCTAssertNil(reason(ledger: spentLedger(), hour: 17))
    }

    func testBudgetIsExhaustedOnlyWhenTheFocusWindowIsAlsoSpent() {
        let ledger = spentLedger().recording(.focusWindow, at: at(12), calendar: utc)
        XCTAssertEqual(reason(ledger: ledger, hour: 17), .budgetExhausted)
    }

    /// Outside work hours the focus window cannot fire either, so a spent
    /// downshift budget does mean there is nothing left to say.
    func testBudgetIsExhaustedOutsideWorkHoursOnceDownshiftsAreSpent() {
        XCTAssertEqual(reason(ledger: spentLedger(), hour: 19), .budgetExhausted)
    }

    /// The reason is what the settings row and the shadow log both read, so it
    /// must survive as a value rather than collapsing to a bool.
    func testSuppressionReasonsAreDistinguishable() {
        XCTAssertNotEqual(reason(standby: true), reason(activity: true))
    }

    // MARK: - Engine

    private final class SpyLog: NudgeShadowLogging {
        var records: [NudgeEvaluation] = []
        func record(_ evaluation: NudgeEvaluation) { records.append(evaluation) }
    }

    /// Fills the engine with `minutes` of still, ordinary ticks ending at `end`.
    @MainActor
    private func fill(_ engine: NudgeEngine, minutes: Int, end: Date) {
        let count = minutes * 2                      // 30s cadence
        for i in 0..<count {
            let t = end.addingTimeInterval(-Double(count - i) * 30)
            engine.ingest(MetricsHistoryPoint(timestamp: t, meanBPM: 62, rmssd: 44,
                                              rsaMs: 35, sdnn: 50, coherence: 0.55,
                                              breathBPM: 14, dfa1: 1.0, dc: 7.0,
                                              motion: 4, signalQuality: 0.98,
                                              ecgQualityTier: 2), now: t)
        }
    }

    @MainActor
    func testThrottlesEvaluationToRoughlyOncePerMinute() {
        let spy = SpyLog()
        let engine = NudgeEngine(log: spy)
        fill(engine, minutes: 35, end: at(10))

        XCTAssertNotNil(engine.evaluate(baseline: NudgeFixture.baseline(), bleStandby: false,
                                        activityInProgress: false, now: at(10), calendar: utc))
        // Ten seconds later: too soon.
        XCTAssertNil(engine.evaluate(baseline: NudgeFixture.baseline(), bleStandby: false,
                                     activityInProgress: false,
                                     now: at(10).addingTimeInterval(10), calendar: utc))
    }

    @MainActor
    func testRecordsSuppressedEvaluationsSoTheLogExplainsQuietDays() {
        let spy = SpyLog()
        let engine = NudgeEngine(log: spy)
        engine.evaluate(baseline: NudgeFixture.baseline(), bleStandby: true,
                        activityInProgress: false, now: at(10), calendar: utc)
        XCTAssertEqual(spy.records.count, 1)
        XCTAssertEqual(spy.records.first?.suppression, .strapOff)
    }

    /// End to end: a long sedentary stretch selects the movement trigger once
    /// sustain is met — and only once.
    @MainActor
    func testSelectsTheSedentaryTriggerAfterSustainAndThenStaysQuiet() {
        let spy = SpyLog()
        let engine = NudgeEngine(log: spy)
        let start = at(10)
        fill(engine, minutes: 60, end: start)        // 60 min still → past the 50-min gate

        var selections = 0
        for i in 0..<10 {
            let t = start.addingTimeInterval(Double(i) * 60)
            if let e = engine.evaluate(baseline: NudgeFixture.baseline(), bleStandby: false,
                                       activityInProgress: false, now: t, calendar: utc),
               e.selected != nil {
                selections += 1
            }
        }
        XCTAssertEqual(selections, 1, "a condition that stays true is reported once")
        XCTAssertTrue(spy.records.contains { $0.selected == .stuckStill })
    }

    @MainActor
    func testPhaseOneNeverDelivers() {
        let spy = SpyLog()
        let engine = NudgeEngine(log: spy)
        fill(engine, minutes: 60, end: at(10))
        engine.evaluate(baseline: NudgeFixture.baseline(), bleStandby: false,
                        activityInProgress: false, now: at(10), calendar: utc)
        XCTAssertTrue(spy.records.allSatisfy(\.shadowed))
    }
}
