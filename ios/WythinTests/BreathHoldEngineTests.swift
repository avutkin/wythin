import XCTest
@testable import Wythin

/// The hold engine's phase mapping, asserted without waiting on real time.
///
/// The order matters more here than in the pacers: this practice puts the hold
/// after the exhale, on empty lungs, which is a materially harder thing than the
/// same seconds on full. If a refactor ever reorders the phases the practice
/// silently becomes a different — and easier — exercise, so the order is pinned
/// explicitly.
final class BreathHoldEngineTests: XCTestCase {

    /// Fixed here rather than taken from `.standard`: these assertions are about
    /// the engine's arithmetic, and should not break when the shipped default
    /// changes. 5s in, 5s out, 20s hold, 5 sets → 30s a set, 150s total.
    private let plan = HoldProtocol(breatheSeconds: 5, holdSeconds: 20, sets: 5)

    // MARK: Phase order within a set

    func testASetRunsInhaleThenExhaleThenHold() {
        let phases = [0, 4, 5, 9, 10, 29].map {
            BreathHoldEngine.state(at: $0, plan: plan).phase
        }
        XCTAssertEqual(phases, [.inhale, .inhale, .exhale, .exhale, .hold, .hold])
    }

    func testTheHoldLandsAfterTheExhaleNotBeforeIt() {
        // The defining property of this practice: at the moment the hold opens,
        // the exhale is already done.
        let atHoldStart = BreathHoldEngine.state(at: plan.breatheSeconds * 2, plan: plan)
        XCTAssertEqual(atHoldStart.phase, .hold)
        XCTAssertEqual(atHoldStart.secondsIntoPhase, 0)

        let momentBefore = BreathHoldEngine.state(at: plan.breatheSeconds * 2 - 1, plan: plan)
        XCTAssertEqual(momentBefore.phase, .exhale)
    }

    func testPhaseBoundariesAreHalfOpenOnTheLeft() {
        XCTAssertEqual(BreathHoldEngine.state(at: 4, plan: plan).phase, .inhale)
        XCTAssertEqual(BreathHoldEngine.state(at: 5, plan: plan).phase, .exhale)
        XCTAssertEqual(BreathHoldEngine.state(at: 9, plan: plan).phase, .exhale)
        XCTAssertEqual(BreathHoldEngine.state(at: 10, plan: plan).phase, .hold)
    }

    // MARK: Sets

    func testSetsAdvanceEveryThirtySeconds() {
        XCTAssertEqual(BreathHoldEngine.state(at: 0,  plan: plan).set, 1)
        XCTAssertEqual(BreathHoldEngine.state(at: 29, plan: plan).set, 1)
        XCTAssertEqual(BreathHoldEngine.state(at: 30, plan: plan).set, 2)
        XCTAssertEqual(BreathHoldEngine.state(at: 30, plan: plan).phase, .inhale)
        XCTAssertEqual(BreathHoldEngine.state(at: 149, plan: plan).set, 5)
    }

    func testEachSetHoldsExactlyOnce() {
        let holdsPerSet = Dictionary(grouping: (0..<plan.totalSeconds).filter {
            BreathHoldEngine.state(at: $0, plan: plan).phase == .hold
        }) { BreathHoldEngine.state(at: $0, plan: plan).set }

        XCTAssertEqual(holdsPerSet.count, plan.sets)
        for (set, seconds) in holdsPerSet {
            XCTAssertEqual(seconds.count, plan.holdSeconds, "set \(set) held for the wrong length")
        }
    }

    // MARK: Finishing

    /// Unlike the pacers this session ends. Running past the last set would make
    /// it a different practice.
    func testTheSessionFinishesAfterTheLastHold() {
        XCTAssertFalse(BreathHoldEngine.state(at: plan.totalSeconds - 1, plan: plan).isFinished)
        XCTAssertTrue(BreathHoldEngine.state(at: plan.totalSeconds, plan: plan).isFinished)
        XCTAssertTrue(BreathHoldEngine.state(at: plan.totalSeconds + 60, plan: plan).isFinished)
    }

    func testTheFinishedStateReportsTheLastSet() {
        let end = BreathHoldEngine.state(at: plan.totalSeconds, plan: plan)
        XCTAssertEqual(end.set, plan.sets)
        XCTAssertEqual(end.secondsLeftInPhase, 0)
    }

    // MARK: The countdown

    func testTheHoldCountsDownToZero() {
        let start = BreathHoldEngine.state(at: 10, plan: plan)
        XCTAssertEqual(start.secondsLeftInPhase, plan.holdSeconds)
        XCTAssertEqual(start.countdown, "0:20")

        let nearlyThere = BreathHoldEngine.state(at: 29, plan: plan)
        XCTAssertEqual(nearlyThere.secondsLeftInPhase, 1)
        XCTAssertEqual(nearlyThere.countdown, "0:01")
    }

    func testTheCountdownFormatsPastAMinute() {
        let long = HoldProtocol(breatheSeconds: 5, holdSeconds: 95, sets: 1)
        XCTAssertEqual(BreathHoldEngine.state(at: 10, plan: long).countdown, "1:35")
    }

    // MARK: Arithmetic on the plan

    func testThePlanReportsItsDoseAndItsShape() {
        XCTAssertEqual(plan.setSeconds, 30)
        XCTAssertEqual(plan.totalSeconds, 150)
        XCTAssertEqual(plan.totalHoldSeconds, 100)
        XCTAssertEqual(plan.label, "20s × 5")
    }

    // MARK: Robustness

    func testNegativeElapsedClampsToTheStart() {
        let s = BreathHoldEngine.state(at: -5, plan: plan)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.set, 1)
        XCTAssertFalse(s.isFinished)
    }

    /// A plan with no sets has nothing to run; it must report finished rather
    /// than dividing by zero.
    func testAnEmptyPlanIsFinishedImmediately() {
        let empty = HoldProtocol(breatheSeconds: 5, holdSeconds: 20, sets: 0)
        XCTAssertTrue(BreathHoldEngine.state(at: 0, plan: empty).isFinished)
    }

    func testASingleSetStillRunsItsFullCourse() {
        let one = HoldProtocol(breatheSeconds: 4, holdSeconds: 15, sets: 1)
        XCTAssertEqual(BreathHoldEngine.state(at: 0,  plan: one).phase, .inhale)
        XCTAssertEqual(BreathHoldEngine.state(at: 4,  plan: one).phase, .exhale)
        XCTAssertEqual(BreathHoldEngine.state(at: 8,  plan: one).phase, .hold)
        XCTAssertEqual(BreathHoldEngine.state(at: 22, plan: one).phase, .hold)
        XCTAssertTrue(BreathHoldEngine.state(at: 23, plan: one).isFinished)
    }

    // MARK: The shipped default

    /// Pinned separately, so changing it is a deliberate act and not a silent
    /// side effect of editing a test.
    func testTheStandardPlanIsTwentySecondsFiveTimes() {
        let standard = HoldProtocol.standard
        XCTAssertEqual(standard.holdSeconds, 20)
        XCTAssertEqual(standard.sets, 5)
        XCTAssertEqual(standard.breatheSeconds, 6)
        XCTAssertEqual(standard.setSeconds, 32)
        XCTAssertEqual(standard.totalHoldSeconds, 100)
    }

    /// The inhale and the exhale are the same length by construction. The dial
    /// animates each over `seconds(phase)`, so if these ever diverged the two
    /// halves of the breath would visibly differ.
    func testTheBreathsAreSymmetric() {
        for plan in [HoldProtocol.standard,
                     HoldProtocol(breatheSeconds: 3, holdSeconds: 45, sets: 2)] {
            XCTAssertEqual(plan.seconds(.inhale), plan.seconds(.exhale))
        }
    }

    // MARK: The sound of a set
    //
    // Asserted as a sequence, because the pattern is what someone follows with
    // their eyes shut. A count landing where a boundary belongs, or any sound at
    // all inside the hold, would be felt immediately and seen by nothing else.

    private func cues(_ plan: HoldProtocol, seconds: Range<Int>) -> [HoldCueEvent] {
        seconds.map { HoldCueEvent.at(BreathHoldEngine.state(at: $0, plan: plan)) }
    }

    func testASetSoundsOutAsCountsATurnAndTwoBoundaries() {
        let p = HoldProtocol(breatheSeconds: 3, holdSeconds: 4, sets: 2)
        XCTAssertEqual(cues(p, seconds: 0..<10), [
            .boundary, .count, .count,     // inhale: long tone, then counts
            .turn,     .count, .count,     // exhale opens on the double
            .boundary, .silent, .silent, .silent,   // hold: opened, then quiet
        ])
    }

    func testTheHoldIsSilentThroughout() {
        let p = HoldProtocol(breatheSeconds: 2, holdSeconds: 30, sets: 1)
        let holdSeconds = (p.breatheSeconds * 2 + 1)..<p.totalSeconds
        XCTAssertTrue(cues(p, seconds: holdSeconds).allSatisfy { $0 == .silent },
                      "nothing should interrupt a hold once it has begun")
    }

    /// The long tone that closes a hold is the same one that opens the next
    /// inhale — one sound doing both jobs, rather than two colliding.
    func testTheNextSetOpensOnABoundaryNotACount() {
        let p = HoldProtocol(breatheSeconds: 3, holdSeconds: 4, sets: 2)
        let secondSetStart = p.setSeconds
        XCTAssertEqual(HoldCueEvent.at(BreathHoldEngine.state(at: secondSetStart, plan: p)), .boundary)
        XCTAssertEqual(BreathHoldEngine.state(at: secondSetStart, plan: p).set, 2)
    }

    func testThereIsExactlyOneTurnAndTwoBoundariesPerSet() {
        let p = HoldProtocol(breatheSeconds: 4, holdSeconds: 6, sets: 3)
        let first = cues(p, seconds: 0..<p.setSeconds)
        XCTAssertEqual(first.filter { $0 == .turn }.count, 1)
        XCTAssertEqual(first.filter { $0 == .boundary }.count, 2)
        XCTAssertEqual(first.filter { $0 == .count }.count, (p.breatheSeconds - 1) * 2)
    }
}
