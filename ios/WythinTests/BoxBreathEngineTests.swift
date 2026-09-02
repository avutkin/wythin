import XCTest
@testable import Wythin

/// Covers the engine's pure timing arithmetic. Nothing here waits on real time —
/// the beat mapping is a function of the beat index precisely so it can be pinned
/// down without a 24-second test.
final class BoxBreathEngineTests: XCTestCase {

    private let box = BreathPattern.box   // 6-6-6-6 beats

    // MARK: Phase boundaries

    func testSessionOpensOnBeatOneOfTheInhale() {
        let s = BoxBreathEngine.state(atBeat: 0, pattern: box)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.beatInPhase, 1)
        XCTAssertEqual(s.cycle, 1)
        XCTAssertTrue(s.isAccent)
    }

    func testLastBeatOfAPhaseStillBelongsToThatPhase() {
        let s = BoxBreathEngine.state(atBeat: 5, pattern: box)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.beatInPhase, 6)
        XCTAssertFalse(s.isAccent)
    }

    func testPhaseTurnsExactlyOnItsBeatCount() {
        let s = BoxBreathEngine.state(atBeat: 6, pattern: box)
        XCTAssertEqual(s.phase, .holdIn)
        XCTAssertEqual(s.beatInPhase, 1)
        XCTAssertTrue(s.isAccent, "the beat that opens a phase carries the accent")
    }

    func testAllFourPhasesInOrderAcrossOneCycle() {
        let expected: [(Int, BreathPhase)] = [
            (0,  .inhale),  (5,  .inhale),
            (6,  .holdIn),  (11, .holdIn),
            (12, .exhale),  (17, .exhale),
            (18, .holdOut), (23, .holdOut),
        ]
        for (beat, phase) in expected {
            XCTAssertEqual(BoxBreathEngine.state(atBeat: beat, pattern: box).phase, phase,
                           "beat \(beat) should be \(phase)")
        }
    }

    // MARK: Cycles

    func testLastBeatOfACycleIsStillThatCycle() {
        let s = BoxBreathEngine.state(atBeat: 23, pattern: box)
        XCTAssertEqual(s.cycle, 1)
        XCTAssertEqual(s.phase, .holdOut)
        XCTAssertEqual(s.beatInPhase, 6)
    }

    func testCycleIncrementsEveryTwentyFourBeats() {
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 24, pattern: box).cycle, 2)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 24, pattern: box).phase, .inhale)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 24, pattern: box).beatInPhase, 1)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 47, pattern: box).cycle, 2)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 48, pattern: box).cycle, 3)
    }

    // MARK: Accents

    /// The whole design rests on this: the accent is the corner turn, at any tempo.
    func testAccentFallsOnlyOnTheFirstBeatOfEachPhase() {
        let accented = (0..<24).filter { BoxBreathEngine.state(atBeat: $0, pattern: box).isAccent }
        XCTAssertEqual(accented, [0, 6, 12, 18], "one accent per phase change, four to a cycle")
    }

    func testAccentStillLandsOnEveryPhaseChangeAtAnotherPace() {
        let fours = BreathPattern.box(beats: 4)
        let accented = (0..<16).filter { BoxBreathEngine.state(atBeat: $0, pattern: fours).isAccent }
        XCTAssertEqual(accented, [0, 4, 8, 12])
    }

    // MARK: Tempo

    func testAtSixtyBPMOneBeatIsOneSecond() {
        XCTAssertEqual(BoxBreathEngine.state(at: 0,    pattern: box, bpm: 60).beatInPhase, 1)
        XCTAssertEqual(BoxBreathEngine.state(at: 5.9,  pattern: box, bpm: 60).phase, .inhale)
        XCTAssertEqual(BoxBreathEngine.state(at: 6.0,  pattern: box, bpm: 60).phase, .holdIn)
        XCTAssertEqual(BoxBreathEngine.state(at: 23.9, pattern: box, bpm: 60).cycle, 1)
        XCTAssertEqual(BoxBreathEngine.state(at: 24.0, pattern: box, bpm: 60).cycle, 2)
    }

    func testDoublingTheTempoHalvesTheWallClock() {
        // 120 BPM → a beat is half a second, so the phase turns at 3 s not 6 s.
        XCTAssertEqual(BoxBreathEngine.state(at: 2.9, pattern: box, bpm: 120).phase, .inhale)
        XCTAssertEqual(BoxBreathEngine.state(at: 3.0, pattern: box, bpm: 120).phase, .holdIn)
        XCTAssertEqual(BoxBreathEngine.state(at: 12.0, pattern: box, bpm: 120).cycle, 2)
    }

    func testBeatDurationFollowsTheTempo() {
        XCTAssertEqual(BoxBreathEngine(pattern: box, bpm: 60).beatDuration,  1.0,  accuracy: 0.0001)
        XCTAssertEqual(BoxBreathEngine(pattern: box, bpm: 120).beatDuration, 0.5,  accuracy: 0.0001)
        XCTAssertEqual(BoxBreathEngine(pattern: box, bpm: 40).beatDuration,  1.5,  accuracy: 0.0001)
    }

    func testCycleSecondsAndRateFollowTempoAndPace() {
        XCTAssertEqual(box.cycleSeconds(bpm: 60), 24, accuracy: 0.0001)
        XCTAssertEqual(box.breathsPerMinute(bpm: 60), 2.5, accuracy: 0.0001)
        XCTAssertEqual(box.cycleSeconds(bpm: 120), 12, accuracy: 0.0001)
        XCTAssertEqual(box.breathsPerMinute(bpm: 120), 5.0, accuracy: 0.0001)

        let fours = BreathPattern.box(beats: 4)
        XCTAssertEqual(fours.cycleSeconds(bpm: 60), 16, accuracy: 0.0001)
        XCTAssertEqual(fours.breathsPerMinute(bpm: 60), 3.75, accuracy: 0.0001)
    }

    // MARK: Reconfiguring

    func testReconfiguringAppliesTheNewPaceAndTempo() {
        let engine = BoxBreathEngine(pattern: box, bpm: 60)
        engine.reconfigure(pattern: .box(beats: 4), bpm: 90)
        XCTAssertEqual(engine.pattern, .box(beats: 4))
        XCTAssertEqual(engine.bpm, 90)
        XCTAssertEqual(engine.state.phase, .inhale, "a settings change restarts the cycle")
        XCTAssertEqual(engine.state.beatInPhase, 1)
    }

    func testTempoIsClampedAwayFromZero() {
        // A zero-BPM clock would never fire and the pacer would hang.
        let engine = BoxBreathEngine(pattern: box, bpm: 0)
        XCTAssertGreaterThan(engine.bpm, 0)
        XCTAssertGreaterThan(engine.beatDuration, 0)
    }

    // MARK: Robustness

    func testNegativeBeatClampsToTheStart() {
        let s = BoxBreathEngine.state(atBeat: -3, pattern: box)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.beatInPhase, 1)
        XCTAssertEqual(s.cycle, 1)
    }

    func testPatternWithNoHoldsSkipsStraightFromInhaleToExhale() {
        let inOut = BreathPattern(inhale: 4, holdIn: 0, exhale: 6, holdOut: 0)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 3,  pattern: inOut).phase, .inhale)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 4,  pattern: inOut).phase, .exhale)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 9,  pattern: inOut).phase, .exhale)
        XCTAssertEqual(BoxBreathEngine.state(atBeat: 10, pattern: inOut).cycle, 2)
    }

    // MARK: Pattern

    func testBoxPatternIsTwentyFourBeatsAndLabelsItself() {
        XCTAssertEqual(box.cycleBeats, 24)
        XCTAssertEqual(box.label, "6-6-6-6")
        XCTAssertEqual(BreathPattern.box(beats: 4).label, "4-4-4-4")
    }

    // MARK: Even cadence
    //
    // The bridge between the seconds people set and the whole beats the engine
    // needs. It has to be exact: a cadence that rounds would move the accent off
    // the phase change, which is the one thing the design guarantees.

    func testAWholeSecondPaceTicksOnceASecond() {
        let c = EvenCadence(halfSeconds: 12)          // 6 s
        XCTAssertEqual(c.seconds, 6, accuracy: 0.0001)
        XCTAssertEqual(c.bpm, 60)
        XCTAssertEqual(c.beats, 6)
        XCTAssertEqual(c.label, "6s")
        XCTAssertEqual(c.breathsPerMinute, 5, accuracy: 0.0001)
    }

    func testAHalfSecondPaceTicksTwiceASecond() {
        let c = EvenCadence.coherent                   // 5.5 s
        XCTAssertEqual(c.seconds, 5.5, accuracy: 0.0001)
        XCTAssertEqual(c.bpm, 120)
        XCTAssertEqual(c.beats, 11)
        XCTAssertEqual(c.label, "5.5s")
        XCTAssertEqual(c.breathsPerMinute, 60.0 / 11.0, accuracy: 0.0001)
    }

    /// However the pace is set, beats × beat-length must land exactly on the
    /// phase, or the accent drifts.
    func testEveryPaceInRangeResolvesToItsExactPhaseLength() {
        for half in EvenCadence.range {
            let c = EvenCadence(halfSeconds: half)
            let phase = Double(c.beats) * 60.0 / Double(c.bpm)
            XCTAssertEqual(phase, c.seconds, accuracy: 0.0001,
                           "\(c.label) resolved to \(c.beats) beats at \(c.bpm) BPM")
            XCTAssertEqual(c.pattern.inhale, c.pattern.exhale)
            XCTAssertFalse(c.pattern.hasHolds)
        }
    }

    /// The catalog declares beats and a tempo; the pace control needs the
    /// seconds back out of them. The round trip has to be lossless.
    func testCadenceRoundTripsThroughBeatsAndTempo() {
        for half in EvenCadence.range {
            let c = EvenCadence(halfSeconds: half)
            XCTAssertEqual(EvenCadence(beats: c.beats, bpm: c.bpm), c)
        }
    }

    /// Every pace the control offers must sit inside the engine's own limits.
    func testThePaceRangeStaysWithinTheEnginesBeatRange() {
        for half in EvenCadence.range {
            let c = EvenCadence(halfSeconds: half)
            XCTAssertTrue((2...16).contains(c.beats), "\(c.label) needs \(c.beats) beats")
            XCTAssertGreaterThan(c.bpm, 0)
        }
    }
}
