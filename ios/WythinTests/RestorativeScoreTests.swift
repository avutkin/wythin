import XCTest
@testable import Wythin

final class RestorativeScoreTests: XCTestCase {

    private func nine(_ v: Double) -> [Double?] { Array(repeating: v, count: 9) }

    // MARK: - Stronger improvements score higher

    func testStrongerImprovementsScoreHigher() {
        let scores = [2.0, 6.0, 10.0, 16.0, 20.0].map { RestorativeScore.score(uplifts: nine($0))! }
        XCTAssertEqual(scores, scores.sorted(), "the score must rise with the improvement")
    }

    func testFullMarksOnEveryMetricScoresOneHundred() {
        XCTAssertEqual(RestorativeScore.score(uplifts: nine(RestorativeScore.fullMarks)), 100)
    }

    func testBeyondFullMarksDoesNotOverflow() {
        XCTAssertEqual(RestorativeScore.score(uplifts: nine(400)), 100)
    }

    func testHalfOfFullMarksScoresAboutHalf() {
        XCTAssertEqual(RestorativeScore.score(uplifts: nine(10))!, 50, accuracy: 1)
    }

    // MARK: - No change is the bottom, not the middle

    func testASessionThatChangedNothingScoresZero() {
        // The old signed meter centred zero, so holding steady looked like the
        // middle of the range. It is the bottom of it.
        XCTAssertEqual(RestorativeScore.score(uplifts: nine(0)), 0)
    }

    func testRegressionsContributeNothingRatherThanNegative() {
        // One badly negative metric must not erase several real improvements.
        let mixed: [Double?] = [20, 20, 20, 20, 20, 20, 20, 20, -500]
        let score = RestorativeScore.score(uplifts: mixed)!
        XCTAssertEqual(score, 89, accuracy: 1, "eight of nine at full marks")
    }

    // MARK: - Missing data

    func testAbsentMetricsAreExcludedNotCountedAsZero() {
        let partial: [Double?] = [20, 20, 20, nil, nil, nil, nil, nil, nil]
        XCTAssertEqual(RestorativeScore.score(uplifts: partial), 100)
    }

    func testTooFewMetricsYieldsNoScore() {
        XCTAssertNil(RestorativeScore.score(uplifts: [20, 20, nil, nil, nil, nil, nil, nil, nil]))
        XCTAssertNil(RestorativeScore.score(uplifts: Array(repeating: nil, count: 9)))
    }

    // MARK: - The count behind the number

    func testImprovedCountReportsBothHalves() {
        let mixed: [Double?] = [5, 5, -3, 0, nil, 8, -1, nil, 2]
        let r = RestorativeScore.improvedCount(uplifts: mixed)
        XCTAssertEqual(r.improved, 4)
        XCTAssertEqual(r.measured, 7)
    }

    // MARK: - Copy

    func testCaptionsRiseWithTheScoreAndNeverScold() {
        XCTAssertEqual(RestorativeScore.caption(95), "deeply restorative")
        XCTAssertEqual(RestorativeScore.caption(5), "held steady")
        for s in 0...100 {
            let c = RestorativeScore.caption(s).lowercased()
            for banned in ["poor", "bad", "failed", "weak"] {
                XCTAssertFalse(c.contains(banned), "score \(s) produced \"\(c)\"")
            }
        }
    }
}
