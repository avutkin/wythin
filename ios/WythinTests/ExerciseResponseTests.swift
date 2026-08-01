import XCTest
@testable import Wythin

final class ExerciseResponseTests: XCTestCase {

    // MARK: - Percentile scoring

    func testCheapestSlopeInHistoryScoresHighest() {
        // A less negative slope is cheaper, so -0.10 beats all of these.
        let history = [-0.20, -0.25, -0.30, -0.35]
        XCTAssertEqual(ExerciseResponse.percentileScore(value: -0.10, history: history,
                                                        lowerIsBetter: false), 100)
    }

    func testCostliestSlopeScoresLowest() {
        let history = [-0.20, -0.25, -0.30, -0.35]
        XCTAssertEqual(ExerciseResponse.percentileScore(value: -0.40, history: history,
                                                        lowerIsBetter: false), 0)
    }

    func testMedianValueScoresNearFifty() {
        let history = [-0.10, -0.20, -0.30, -0.40]
        let score = ExerciseResponse.percentileScore(value: -0.25, history: history,
                                                     lowerIsBetter: false)!
        XCTAssertEqual(Double(score), 50, accuracy: 15)
    }

    func testTooLittleHistoryYieldsNoScore() {
        XCTAssertNil(ExerciseResponse.percentileScore(value: -0.2, history: [-0.3, -0.25],
                                                      lowerIsBetter: false))
    }

    // MARK: - Recovery, phase 1: a single checkpoint

    func testReactivationScoresAndReadsProvisional() {
        guard case let .score(value, word) =
                ExerciseResponse.reactivationScore(dcAfter: 4.1, dcPre: 10) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(value, 41)
        XCTAssertEqual(word, "provisional · 1 of 7",
                       "phase 1 has one checkpoint of seven and must say so")
    }

    func testReactivationIsUnavailableWithoutABaseline() {
        guard case let .unavailable(reason) =
                ExerciseResponse.reactivationScore(dcAfter: 4.1, dcPre: nil) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testReactivationAboveBaselineCapsAtOneHundred() {
        guard case let .score(value, _) =
                ExerciseResponse.reactivationScore(dcAfter: 14, dcPre: 10) else {
            return XCTFail("expected a score")
        }
        XCTAssertEqual(value, 100)
    }

    // MARK: - Absence is stated, never guessed

    func testTwoKindsOfEmptinessReadDifferently() {
        let thin = ExerciseResponse.efficiency(slope: -0.2, history: [-0.3],
                                               hasExternalSignal: true)
        guard case let .unavailable(r1) = thin else { return XCTFail("expected unavailable") }
        XCTAssertTrue(r1.contains("of 3"), "thin history must show progress toward a baseline")

        let noSignal = ExerciseResponse.efficiency(slope: nil, history: [],
                                                   hasExternalSignal: false)
        guard case let .unavailable(r2) = noSignal else { return XCTFail("expected unavailable") }
        XCTAssertTrue(r2.lowercased().contains("signal"),
                      "a missing denominator is a different absence from a thin history")
        XCTAssertNotEqual(r1, r2)
    }

    func testEfficiencyRefusesToBorrowHeartRateAsADenominator() {
        // Suppression already normalises by HR. If Efficiency fell back to it,
        // the two axes would be the same number twice.
        let withHistory = [-0.1, -0.2, -0.3, -0.4]
        guard case .unavailable = ExerciseResponse.efficiency(slope: -0.2,
                                                              history: withHistory,
                                                              hasExternalSignal: false) else {
            return XCTFail("no external signal must mean no score, even with history")
        }
    }

    func testSuppressionIsUnavailableWithoutAFit() {
        guard case let .unavailable(reason) =
                ExerciseResponse.suppression(slope: nil, history: [-0.1, -0.2, -0.3]) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Copy rules

    func testNoScoreIsEverCalledPoor() {
        for score in 0...100 {
            let w = ExerciseResponse.word(for: score).lowercased()
            XCTAssertFalse(w.contains("poor"), "score \(score) produced \"\(w)\"")
            XCTAssertFalse(w.contains("bad"), "score \(score) produced \"\(w)\"")
        }
    }

    func testWordsRunFromCostlyToCheap() {
        XCTAssertEqual(ExerciseResponse.word(for: 95), "cheap")
        XCTAssertEqual(ExerciseResponse.word(for: 50), "typical")
        XCTAssertEqual(ExerciseResponse.word(for: 5), "costly")
    }
}
