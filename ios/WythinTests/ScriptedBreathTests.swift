import XCTest
@testable import Wythin

/// A scripted breath is guided by sound as much as by the screen, and someone
/// following it has their eyes half shut. The cue mapping and the walk through
/// the steps are therefore asserted directly rather than trusted to look right.
final class ScriptedBreathTests: XCTestCase {

    private let stacking  = BreathScript.stacking
    private let retention = BreathScript.retention

    // MARK: The scripts themselves

    func testStackingIsInhalePumpTopUpRelease() {
        XCTAssertEqual(stacking.steps.map(\.move), [.inhale, .pump, .topUp, .exhale])
        XCTAssertTrue(stacking.steps[0].pace.isNatural, "the first breath is your own")
        XCTAssertFalse(stacking.steps[1].pace.isNatural, "the pump is counted")
        XCTAssertFalse(stacking.steps[2].pace.isNatural, "the top-up is counted")
        XCTAssertTrue(stacking.steps[3].pace.isNatural, "the release is your own")
        XCTAssertFalse(stacking.hasLongHolds)
    }

    func testRetentionHoldsBothEndsAndFinishesEachOne() {
        XCTAssertEqual(retention.steps.map(\.move),
                       [.inhale, .holdIn, .topUp, .exhale, .holdOut, .squeezeOut])
        XCTAssertTrue(retention.hasLongHolds)
        // The move after each long hold is the one that goes a step further than
        // the breath wanted to: a sip at the top, a squeeze at the bottom.
        XCTAssertEqual(retention.steps[2].move, .topUp)
        XCTAssertEqual(retention.steps[5].move, .squeezeOut)
        // Both natural breaths are self-paced — chasing a count straight out of a
        // retention is how people over-breathe.
        XCTAssertTrue(retention.steps[0].pace.isNatural)
        XCTAssertTrue(retention.steps[3].pace.isNatural)
    }

    func testEveryShippedStepHasAPositiveLength() {
        for script in [stacking, retention] {
            XCTAssertFalse(script.steps.isEmpty)
            for step in script.steps {
                XCTAssertGreaterThan(step.pace.seconds, 0, "\(step.move.rawValue): zero-length step")
            }
            XCTAssertGreaterThan(script.cycleSeconds, 0)
        }
    }

    /// A hold keeps whatever the move before it left; everything else states
    /// where the lungs end up. The two moves that go past a normal breath have to
    /// sit outside the range a normal breath reaches.
    func testFillTargetsOrderTheMovesCorrectly() {
        XCTAssertNil(BreathMove.holdIn.fill)
        XCTAssertNil(BreathMove.holdOut.fill)
        guard let inhale = BreathMove.inhale.fill,
              let pump   = BreathMove.pump.fill,
              let topUp  = BreathMove.topUp.fill,
              let exhale = BreathMove.exhale.fill,
              let squeeze = BreathMove.squeezeOut.fill else {
            return XCTFail("a moving step is missing its fill target")
        }
        XCTAssertLessThan(inhale, pump)
        XCTAssertLessThan(pump, topUp)
        XCTAssertEqual(topUp, 1.0, "the top-up is the fullest the practice gets")
        XCTAssertLessThan(squeeze, exhale)
        XCTAssertEqual(squeeze, 0.0, "the squeeze is the emptiest the practice gets")
    }

    // MARK: Resizing

    func testResizingMovesTheHoldsAndTheNaturalBreathsOnly() {
        let sized = retention.resized(hold: 25, natural: 6)
        XCTAssertEqual(sized.steps[1].pace, .counted(25), "the full hold takes the hold setting")
        XCTAssertEqual(sized.steps[4].pace, .counted(25), "so does the empty one")
        XCTAssertEqual(sized.steps[0].pace, .natural(6))
        XCTAssertEqual(sized.steps[3].pace, .natural(6))
        // The short moves are part of what the move is, not a preference.
        XCTAssertEqual(sized.steps[2].pace, retention.steps[2].pace, "the top-up keeps its length")
        XCTAssertEqual(sized.steps[5].pace, retention.steps[5].pace, "the squeeze keeps its length")
        XCTAssertEqual(sized.steps.map(\.move), retention.steps.map(\.move), "resizing never reorders")
    }

    func testResizingNeverProducesAZeroLengthStep() {
        let sized = retention.resized(hold: 0, natural: -3)
        for step in sized.steps {
            XCTAssertGreaterThan(step.pace.seconds, 0, "\(step.move.rawValue) collapsed")
        }
    }

    // MARK: Walking the cycle

    func testTickingWalksEveryStepAndCountsTheCycle() {
        let script = retention.resized(hold: 5, natural: 3)   // 3+5+2+3+5+2 = 20 s
        var state  = ScriptedBreathEngine.opening(script)
        XCTAssertEqual(state.stepIndex, 0)
        XCTAssertEqual(state.cycle, 1)

        var seen: [BreathMove] = [script.steps[0].move]
        for _ in 1...script.cycleSeconds {
            let before = state.stepIndex
            state = ScriptedBreathEngine.ticked(from: state, in: script)
            if state.stepIndex != before { seen.append(script.steps[state.stepIndex].move) }
        }
        // One full lap lands back on the opening move, one cycle further on.
        XCTAssertEqual(seen, script.steps.map(\.move) + [script.steps[0].move])
        XCTAssertEqual(state.stepIndex, 0)
        XCTAssertEqual(state.cycle, 2)
        XCTAssertEqual(state.secondsIntoStep, 0)
    }

    func testTheCountdownReachesOneAndNeverZeroWithinAStep() {
        let script = BreathScript(steps: [BreathStep(move: .holdIn, pace: .counted(4)),
                                          BreathStep(move: .exhale, pace: .natural(3))])
        var state = ScriptedBreathEngine.opening(script)
        XCTAssertEqual(state.secondsLeftInStep, 4)
        var lefts: [Int] = [state.secondsLeftInStep]
        for _ in 1...3 {
            state = ScriptedBreathEngine.ticked(from: state, in: script)
            lefts.append(state.secondsLeftInStep)
        }
        XCTAssertEqual(lefts, [4, 3, 2, 1], "a hold counts down to one, then hands over")
        state = ScriptedBreathEngine.ticked(from: state, in: script)
        XCTAssertEqual(state.stepIndex, 1, "the fourth second ends the hold")
    }

    func testAdvanceSkipsToTheNextStepAndWrapsTheCycle() {
        var state = ScriptedBreathEngine.opening(stacking)
        for expected in 1..<stacking.steps.count {
            state = ScriptedBreathEngine.advanced(from: state, in: stacking)
            XCTAssertEqual(state.stepIndex, expected)
            XCTAssertEqual(state.cycle, 1)
            XCTAssertEqual(state.secondsIntoStep, 0, "a skipped-to step starts at its beginning")
        }
        state = ScriptedBreathEngine.advanced(from: state, in: stacking)
        XCTAssertEqual(state.stepIndex, 0)
        XCTAssertEqual(state.cycle, 2)
    }

    // MARK: What the ear hears

    func testEveryStepOpensWithSomethingAudible() {
        for script in [stacking, retention] {
            for index in script.steps.indices {
                let state = ScriptedBreathState(stepIndex: index, cycle: 1, secondsIntoStep: 0,
                                                secondsLeftInStep: script.steps[index].pace.seconds)
                XCTAssertNotEqual(ScriptedBreathEngine.cue(at: state, script: script), .silent,
                                  "\(script.steps[index].move.rawValue) opened silently")
            }
        }
    }

    /// The natural breaths are walked through by a sound of their own, and its
    /// direction has to match the breath — an inhale cued by the falling sound
    /// is worse than no cue at all.
    func testTheNaturalBreathsAreCuedInTheirOwnDirection() {
        for script in [stacking, retention] {
            for (index, step) in script.steps.enumerated() where step.pace.isNatural {
                let state = ScriptedBreathState(stepIndex: index, cycle: 1, secondsIntoStep: 0,
                                                secondsLeftInStep: step.pace.seconds)
                let cue = ScriptedBreathEngine.cue(at: state, script: script)
                XCTAssertEqual(cue, step.move == .inhale ? .breatheIn : .breatheOut,
                               "\(step.move.rawValue) was walked in the wrong direction")
            }
        }
    }

    /// One effort, cued once and hard, and never counted. The direction of the
    /// sweep is the instruction: up past full, down past empty.
    func testASurgeIsOneHardCueAndThenNothing() {
        let script = retention
        for (index, step) in script.steps.enumerated() where step.move.isSurge {
            let opening = ScriptedBreathState(stepIndex: index, cycle: 1, secondsIntoStep: 0,
                                              secondsLeftInStep: step.pace.seconds)
            XCTAssertEqual(ScriptedBreathEngine.cue(at: opening, script: script),
                           step.move == .topUp ? .surgeUp : .surgeDown)
            for second in 1..<max(2, step.pace.seconds) {
                let later = ScriptedBreathState(stepIndex: index, cycle: 1, secondsIntoStep: second,
                                                secondsLeftInStep: step.pace.seconds - second)
                XCTAssertEqual(ScriptedBreathEngine.cue(at: later, script: script), .silent,
                               "\(step.move.rawValue) was counted through")
            }
        }
        XCTAssertTrue(BreathMove.topUp.isSurge)
        XCTAssertTrue(BreathMove.squeezeOut.isSurge)
        XCTAssertFalse(BreathMove.pump.isSurge, "the pump is a sustained widening, so it is counted")
    }

    /// The breath sound runs the length of the step, so nothing else plays over
    /// it. Being clicked at through a breath you are meant to take at your own
    /// speed is the bug this asserts against.
    func testANaturalStepIsSilentAfterItsBreathSound() {
        let script = stacking.resized(hold: 15, natural: 6)
        for second in 1..<6 {
            let state = ScriptedBreathState(stepIndex: 0, cycle: 1, secondsIntoStep: second,
                                            secondsLeftInStep: 6 - second)
            XCTAssertEqual(ScriptedBreathEngine.cue(at: state, script: script), .silent)
        }
    }

    func testALongHoldIsSilentExceptForItsWarning() {
        let script = retention.resized(hold: 15, natural: 4)
        let holdIndex = 1
        var events: [Int: ScriptedCue.Event] = [:]
        for second in 1..<15 {
            let state = ScriptedBreathState(stepIndex: holdIndex, cycle: 1,
                                            secondsIntoStep: second,
                                            secondsLeftInStep: 15 - second)
            events[15 - second] = ScriptedBreathEngine.cue(at: state, script: script)
        }
        XCTAssertEqual(events[3], .warn, "three seconds out, a double warns the top-up is coming")
        for (left, event) in events where left != 3 {
            XCTAssertEqual(event, .silent, "the hold made a noise with \(left)s left")
        }
    }

    func testAShortCountedMoveIsCountedOut() {
        let script = stacking
        let pumpIndex = 1
        let seconds = script.steps[pumpIndex].pace.seconds
        for second in 1..<seconds {
            let state = ScriptedBreathState(stepIndex: pumpIndex, cycle: 1, secondsIntoStep: second,
                                            secondsLeftInStep: seconds - second)
            XCTAssertEqual(ScriptedBreathEngine.cue(at: state, script: script), .count)
        }
    }

    func testAnOutOfRangeStepIsSilentRatherThanCrashing() {
        let state = ScriptedBreathState(stepIndex: 99, cycle: 1, secondsIntoStep: 1,
                                        secondsLeftInStep: 1)
        XCTAssertEqual(ScriptedBreathEngine.cue(at: state, script: stacking), .silent)
    }

    // MARK: The practices that use them

    func testBothScriptedPracticesAreInTheCatalogWithAScript() {
        let scripted = PracticeCatalog.practices.filter { $0.breathScript != nil }
        XCTAssertEqual(scripted.map(\.id), ["breath-stacking", "breath-retention-15x15"])
        for practice in scripted {
            XCTAssertNil(practice.breathPattern, "a scripted practice is not a pacer")
            XCTAssertEqual(practice.activityType, .breathwork)
            XCTAssertNotNil(practice.subtype)
        }
    }

    func testRetentionShipsOnFifteenAtBothEnds() {
        guard let practice = PracticeCatalog.practices.first(where: { $0.id == "breath-retention-15x15" }),
              let script = practice.breathScript else {
            return XCTFail("breath-retention-15x15 missing from the catalog")
        }
        let holds = script.steps.filter(\.move.isLongHold)
        XCTAssertEqual(holds.count, 2, "one hold full, one empty — that is the practice")
        for hold in holds {
            XCTAssertEqual(hold.pace, .counted(15), "the title says fifteen at both ends")
        }
    }

    /// Holding on empty can make someone faint, so the warning is part of the
    /// content rather than something a screen happens to render.
    func testRetentionWarnsAboutWaterInItsDescription() {
        guard let practice = PracticeCatalog.practices.first(where: { $0.id == "breath-retention-15x15" }) else {
            return XCTFail("breath-retention-15x15 missing")
        }
        XCTAssertTrue(practice.description.lowercased().contains("water"),
                      "the description must carry the water warning")
    }
}
