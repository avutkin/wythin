import XCTest
@testable import Wythin

/// Everything between "the state matches" and "the user is interrupted":
/// sustain, hysteresis, precedence, and the daily budget.
final class NudgeGatingTests: XCTestCase {

    private let sustain = 3
    private let cooldown: TimeInterval = 30 * 60

    private func run(_ steps: [(passed: Bool, released: Bool)],
                     from start: Date = Date(),
                     spacing: TimeInterval = 60) -> (state: NudgeTriggerState, fires: Int) {
        var state = NudgeTriggerState()
        var fires = 0
        for (i, step) in steps.enumerated() {
            let (next, didFire) = NudgeStateMachine.advance(
                state, passed: step.passed, released: step.released,
                now: start.addingTimeInterval(Double(i) * spacing),
                sustain: sustain, cooldown: cooldown)
            state = next
            if didFire { fires += 1 }
        }
        return (state, fires)
    }

    private func passes(_ n: Int) -> [(passed: Bool, released: Bool)] {
        Array(repeating: (passed: true, released: false), count: n)
    }

    // MARK: - Sustain

    func testDoesNotFireBeforeSustainIsReached() {
        XCTAssertEqual(run(passes(sustain - 1)).fires, 0)
    }

    func testFiresOnTheSustainthConsecutivePass() {
        XCTAssertEqual(run(passes(sustain)).fires, 1)
    }

    /// Sustain exists to reject a single bad tick, so any failure restarts it.
    func testAFailedEvaluationRestartsTheCount() {
        let steps = passes(2) + [(passed: false, released: false)] + passes(2)
        XCTAssertEqual(run(steps).fires, 0)
    }

    /// The anti-flap property: a signal sitting on the threshold and crossing
    /// back and forth must never produce a notification.
    func testFlappingNeverFires() {
        let steps = (0..<40).map { (passed: $0.isMultiple(of: 2), released: false) }
        XCTAssertEqual(run(steps).fires, 0)
    }

    // MARK: - The anti-nag rule

    /// A condition that stays true is reported once. If inner arousal is high
    /// all afternoon the user is told once, not three times.
    func testDoesNotRefireWhileTheConditionRemainsTrue() {
        XCTAssertEqual(run(passes(30)).fires, 1)
    }

    func testRequiresTwoConsecutiveReleasesBeforeRearming() {
        // Fire, then a single release followed by the condition returning.
        let steps = passes(sustain)
            + [(passed: false, released: true), (passed: true, released: false)]
            + passes(sustain)
        XCTAssertEqual(run(steps).fires, 1)
    }

    func testDoesNotRearmBeforeTheCooldownElapses() {
        // Two releases, but only minutes later.
        let steps = passes(sustain)
            + [(passed: false, released: true), (passed: false, released: true)]
            + passes(sustain)
        XCTAssertEqual(run(steps, spacing: 60).fires, 1)
    }

    func testFiresAgainAfterReleaseAndCooldown() {
        // Same shape, but each step is 15 minutes so the cooldown clears.
        let steps = passes(sustain)
            + [(passed: false, released: true), (passed: false, released: true)]
            + passes(sustain)
        XCTAssertEqual(run(steps, spacing: 15 * 60).fires, 2)
    }

    // MARK: - Precedence

    func testFocusWindowOutranksEverything() {
        let picked = NudgePrecedence.select([.stuckStill, .focusWindow, .vagalWithdrawal])
        XCTAssertEqual(picked, .focusWindow)
    }

    func testAcuteSpikeOutranksTheSlowTriggers() {
        XCTAssertEqual(NudgePrecedence.select([.stuckStill, .vagalWithdrawal, .acuteSpike]),
                       .acuteSpike)
    }

    func testStillnessIsTheLastResort() {
        XCTAssertEqual(NudgePrecedence.select([.stuckStill, .sustainedLoad]), .sustainedLoad)
    }

    func testSelectsNothingFromAnEmptySet() {
        XCTAssertNil(NudgePrecedence.select([]))
    }

    // MARK: - Budget

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 7, day: day,
                                      hour: hour, minute: minute))!
    }

    func testQuietHoursCoverTheNight() {
        XCTAssertFalse(NudgeBudget.isQuietHours(at(21, 59), calendar: utc))
        XCTAssertTrue(NudgeBudget.isQuietHours(at(22, 0), calendar: utc))
        XCTAssertTrue(NudgeBudget.isQuietHours(at(3, 0), calendar: utc))
        XCTAssertTrue(NudgeBudget.isQuietHours(at(6, 59), calendar: utc))
        XCTAssertFalse(NudgeBudget.isQuietHours(at(7, 0), calendar: utc))
    }

    func testAllowsTheFirstNudgeOfTheDay() {
        let ledger = NudgeLedger()
        XCTAssertTrue(NudgeBudget.allows(.vagalWithdrawal, ledger: ledger,
                                         now: at(10), calendar: utc))
    }

    func testEnforcesMinimumSpacing() {
        var ledger = NudgeLedger()
        ledger = ledger.recording(.vagalWithdrawal, at: at(10), calendar: utc)
        XCTAssertFalse(NudgeBudget.allows(.sustainedLoad, ledger: ledger,
                                          now: at(11, 29), calendar: utc))
        XCTAssertTrue(NudgeBudget.allows(.sustainedLoad, ledger: ledger,
                                         now: at(11, 31), calendar: utc))
    }

    func testEnforcesTheDailyCap() {
        var ledger = NudgeLedger()
        ledger = ledger.recording(.vagalWithdrawal, at: at(8),  calendar: utc)
        ledger = ledger.recording(.sustainedLoad,   at: at(11), calendar: utc)
        ledger = ledger.recording(.stuckStill,      at: at(14), calendar: utc)
        XCTAssertFalse(NudgeBudget.allows(.acuteSpike, ledger: ledger,
                                          now: at(17), calendar: utc))
    }

    /// One rule must not consume the whole daily allowance.
    func testTheSameTriggerCannotRepeatWithinThreeHours() {
        var ledger = NudgeLedger()
        ledger = ledger.recording(.vagalWithdrawal, at: at(10), calendar: utc)
        XCTAssertFalse(NudgeBudget.allows(.vagalWithdrawal, ledger: ledger,
                                          now: at(12, 30), calendar: utc))
        XCTAssertTrue(NudgeBudget.allows(.vagalWithdrawal, ledger: ledger,
                                         now: at(13, 30), calendar: utc))
    }

    func testTheDailyCapResetsAtMidnight() {
        var ledger = NudgeLedger()
        ledger = ledger.recording(.vagalWithdrawal, at: at(20, 0, day: 15), calendar: utc)
        ledger = ledger.recording(.sustainedLoad,   at: at(21, 0, day: 15), calendar: utc)
        ledger = ledger.recording(.stuckStill,      at: at(21, 30, day: 15), calendar: utc)
        XCTAssertTrue(NudgeBudget.allows(.vagalWithdrawal, ledger: ledger,
                                         now: at(9, 0, day: 16), calendar: utc))
    }

    // MARK: Focus window budget

    /// The focus window is silent, so it is exempt from spacing and the
    /// downshift cap — but capped at one a day and confined to work hours.
    func testFocusWindowIsAllowedOncePerDay() {
        var ledger = NudgeLedger()
        XCTAssertTrue(NudgeBudget.allows(.focusWindow, ledger: ledger, now: at(11), calendar: utc))
        ledger = ledger.recording(.focusWindow, at: at(11), calendar: utc)
        XCTAssertFalse(NudgeBudget.allows(.focusWindow, ledger: ledger, now: at(15), calendar: utc))
    }

    func testFocusWindowIsConfinedToWorkHours() {
        let ledger = NudgeLedger()
        XCTAssertFalse(NudgeBudget.allows(.focusWindow, ledger: ledger, now: at(7), calendar: utc))
        XCTAssertTrue(NudgeBudget.allows(.focusWindow, ledger: ledger, now: at(9), calendar: utc))
        XCTAssertTrue(NudgeBudget.allows(.focusWindow, ledger: ledger, now: at(17), calendar: utc))
        XCTAssertFalse(NudgeBudget.allows(.focusWindow, ledger: ledger, now: at(19), calendar: utc))
    }

    func testFocusWindowDoesNotConsumeTheDownshiftBudget() {
        var ledger = NudgeLedger()
        ledger = ledger.recording(.focusWindow, at: at(11), calendar: utc)
        XCTAssertTrue(NudgeBudget.allows(.vagalWithdrawal, ledger: ledger,
                                         now: at(11, 30), calendar: utc))
    }

    func testDownshiftIsBlockedDuringQuietHours() {
        XCTAssertFalse(NudgeBudget.allows(.vagalWithdrawal, ledger: NudgeLedger(),
                                          now: at(23), calendar: utc))
    }
}
