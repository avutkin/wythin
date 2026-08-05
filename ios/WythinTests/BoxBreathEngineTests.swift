import XCTest
@testable import Wythin

/// Covers the engine's pure timing arithmetic. Nothing here waits on real time —
/// `state(at:pattern:)` is a function of elapsed seconds precisely so the beat
/// mapping can be pinned down without a 24-second test.
final class BoxBreathEngineTests: XCTestCase {

    private let box = BreathPattern.box   // 6-6-6-6

    // MARK: Phase boundaries

    func testSessionOpensOnBeatOneOfTheInhale() {
        let s = BoxBreathEngine.state(at: 0, pattern: box)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.beatInPhase, 1)
        XCTAssertEqual(s.cycle, 1)
        XCTAssertTrue(s.isAccent)
    }

    func testLastInstantOfAPhaseStillBelongsToThatPhase() {
        let s = BoxBreathEngine.state(at: 5.9, pattern: box)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.beatInPhase, 6)
    }

    func testPhaseTurnsExactlyOnItsLength() {
        let s = BoxBreathEngine.state(at: 6.0, pattern: box)
        XCTAssertEqual(s.phase, .holdIn)
        XCTAssertEqual(s.beatInPhase, 1)
        XCTAssertTrue(s.isAccent, "the beat that opens a phase carries the accent")
    }

    func testAllFourPhasesInOrderAcrossOneCycle() {
        let expected: [(TimeInterval, BreathPhase)] = [
            (0,  .inhale),  (5,  .inhale),
            (6,  .holdIn),  (11, .holdIn),
            (12, .exhale),  (17, .exhale),
            (18, .holdOut), (23, .holdOut),
        ]
        for (t, phase) in expected {
            XCTAssertEqual(BoxBreathEngine.state(at: t, pattern: box).phase, phase,
                           "t=\(t) should be \(phase)")
        }
    }

    // MARK: Cycles

    func testLastInstantOfACycleIsStillThatCycle() {
        let s = BoxBreathEngine.state(at: 23.9, pattern: box)
        XCTAssertEqual(s.cycle, 1)
        XCTAssertEqual(s.phase, .holdOut)
        XCTAssertEqual(s.beatInPhase, 6)
    }

    func testCycleIncrementsEveryTwentyFourSeconds() {
        XCTAssertEqual(BoxBreathEngine.state(at: 24.0, pattern: box).cycle, 2)
        XCTAssertEqual(BoxBreathEngine.state(at: 24.0, pattern: box).phase, .inhale)
        XCTAssertEqual(BoxBreathEngine.state(at: 24.0, pattern: box).beatInPhase, 1)
        XCTAssertEqual(BoxBreathEngine.state(at: 47.9, pattern: box).cycle, 2)
        XCTAssertEqual(BoxBreathEngine.state(at: 48.0, pattern: box).cycle, 3)
    }

    // MARK: Accents

    func testAccentFallsOnlyOnTheFirstBeatOfEachPhase() {
        let accented = (0..<24).filter { BoxBreathEngine.state(at: TimeInterval($0), pattern: box).isAccent }
        XCTAssertEqual(accented, [0, 6, 12, 18],
                       "one accent per phase change, four to a cycle")
    }

    // MARK: Progress

    func testPhaseProgressRunsZeroToFiveSixthsWithinAPhase() {
        let engine = BoxBreathEngine(pattern: box)
        XCTAssertEqual(engine.phaseProgress, 0, accuracy: 0.001)
    }

    // MARK: Robustness

    func testNegativeElapsedClampsToTheStart() {
        let s = BoxBreathEngine.state(at: -3, pattern: box)
        XCTAssertEqual(s.phase, .inhale)
        XCTAssertEqual(s.beatInPhase, 1)
        XCTAssertEqual(s.cycle, 1)
    }

    func testPatternWithNoHoldsSkipsStraightFromInhaleToExhale() {
        let inOut = BreathPattern(inhale: 4, holdIn: 0, exhale: 6, holdOut: 0)
        XCTAssertEqual(BoxBreathEngine.state(at: 3, pattern: inOut).phase, .inhale)
        XCTAssertEqual(BoxBreathEngine.state(at: 4, pattern: inOut).phase, .exhale)
        XCTAssertEqual(BoxBreathEngine.state(at: 9, pattern: inOut).phase, .exhale)
        XCTAssertEqual(BoxBreathEngine.state(at: 10, pattern: inOut).cycle, 2)
    }

    // MARK: Pattern

    func testBoxPatternIsTwentyFourSecondsAndLabelsItself() {
        XCTAssertEqual(box.cycleSeconds, 24)
        XCTAssertEqual(box.label, "6-6-6-6")
    }
}
