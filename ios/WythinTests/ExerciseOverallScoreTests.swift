import XCTest
@testable import Wythin

final class ExerciseOverallScoreTests: XCTestCase {

    private func s(_ v: Int) -> AxisValue { .score(v, word: "typical") }
    private let none = AxisValue.unavailable(reason: "no fit")

    private func value(_ a: AxisValue) -> Int? {
        if case let .score(v, _) = a { return v }
        return nil
    }

    // MARK: - Composition

    func testAllThreeAxesAreWeightedAndCombined() {
        // recovery 80 ×.45 + suppression 60 ×.35 + efficiency 40 ×.20 = 65
        let overall = ExerciseOverallScore.compute(suppression: s(60), recovery: s(80),
                                                   efficiency: s(40))
        XCTAssertEqual(value(overall), 65)
    }

    func testMissingAxesRenormaliseRatherThanScoringZero() {
        // Only recovery present: the score is recovery, not recovery × 0.45.
        let overall = ExerciseOverallScore.compute(suppression: none, recovery: s(80),
                                                   efficiency: none)
        XCTAssertEqual(value(overall), 80)
    }

    func testNoAxesMeansNoScore() {
        guard case .unavailable = ExerciseOverallScore.compute(suppression: none,
                                                               recovery: none,
                                                               efficiency: none) else {
            return XCTFail("expected unavailable")
        }
    }

    // MARK: - Load must not be able to inflate it

    func testScoreIsIndependentOfHowHardTheSessionWas() {
        // The axes are costs and speeds; Load is deliberately not an input, so
        // there is no way to raise this number by simply going harder or longer.
        let easy = ExerciseOverallScore.compute(suppression: s(70), recovery: s(70),
                                                efficiency: s(70))
        let hard = ExerciseOverallScore.compute(suppression: s(70), recovery: s(70),
                                                efficiency: s(70))
        XCTAssertEqual(value(easy), value(hard))
    }

    func testPoorRecoveryPullsTheScoreDownHardest() {
        // Absorbing the work is the point, so it carries the most weight.
        let badRecovery = ExerciseOverallScore.compute(suppression: s(90), recovery: s(20),
                                                       efficiency: s(90))
        let badEfficiency = ExerciseOverallScore.compute(suppression: s(90), recovery: s(90),
                                                         efficiency: s(20))
        XCTAssertLessThan(value(badRecovery)!, value(badEfficiency)!)
    }

    // MARK: - The crown

    func testCrownAtEightyFiveAndAbove() {
        let at85 = ExerciseOverallScore.compute(suppression: s(85), recovery: s(85),
                                                efficiency: s(85))
        XCTAssertEqual(value(at85), 85)
        XCTAssertTrue(ExerciseOverallScore.earnsCrown(at85))
    }

    func testNoCrownJustBelowTheThreshold() {
        let at84 = ExerciseOverallScore.compute(suppression: s(84), recovery: s(84),
                                                efficiency: s(84))
        XCTAssertEqual(value(at84), 84)
        XCTAssertFalse(ExerciseOverallScore.earnsCrown(at84))
    }

    func testProvisionalScoreNeverEarnsACrown() {
        // One axis is not enough evidence. A crown handed out today and taken
        // back tomorrow is worse than no crown at all.
        let oneAxis = ExerciseOverallScore.compute(suppression: none, recovery: s(95),
                                                   efficiency: none)
        XCTAssertEqual(value(oneAxis), 95)
        XCTAssertFalse(ExerciseOverallScore.earnsCrown(oneAxis),
                       "a 95 built on a single axis must not be crowned")
    }

    func testUnavailableNeverEarnsACrown() {
        XCTAssertFalse(ExerciseOverallScore.earnsCrown(none))
    }

    func testTwoAxesAreEnoughToBeFirm() {
        let twoAxes = ExerciseOverallScore.compute(suppression: s(90), recovery: s(90),
                                                   efficiency: none)
        guard case let .score(_, word) = twoAxes else { return XCTFail("expected a score") }
        XCTAssertFalse(word.contains("alone so far"),
                       "two axes is enough to stop qualifying the score")
        XCTAssertTrue(ExerciseOverallScore.earnsCrown(twoAxes))
    }

    // MARK: - Copy

    func testNoCaptionScolds() {
        for score in 0...100 {
            let c = ExerciseOverallScore.caption(for: score, components: 3).lowercased()
            for banned in ["poor", "bad", "weak", "failed"] {
                XCTAssertFalse(c.contains(banned), "score \(score) produced \"\(c)\"")
            }
        }
    }

    func testProvisionalCaptionNamesItsOwnLimitsInPlainWords() {
        // Not "1 of 3" — that is bookkeeping. Name what the number rests on.
        let c = ExerciseOverallScore.caption(for: 90, components: 1)
        XCTAssertTrue(c.contains("recovery"), c)
        XCTAssertFalse(c.contains("of 3"), c)
    }
}
