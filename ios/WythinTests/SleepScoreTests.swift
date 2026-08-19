import XCTest
@testable import Wythin

final class SleepScoreTests: XCTestCase {

    /// A settled night: on-time, long enough, unbroken, a deep well-placed
    /// heart-rate nadir, and steady breathing.
    private func settled() -> SleepScoreInput {
        SleepScoreInput(regularityIndex: 84,
                        asleepSec: 7.33 * 3600,
                        needSec: 7.75 * 3600,
                        wakeBouts: 3,
                        longestUnbrokenSec: 2.8 * 3600,
                        hrNadirDip: 14,
                        hrNadirFraction: 0.45,
                        meanRMSSD: 52,
                        steadyFraction: 0.965)
    }

    func testSectionsAndOverallAreTheWeightedMean() {
        let s = SleepScore.compute(settled())

        XCTAssertEqual(s.sections.count, 5)
        guard let overall = s.overall else { return XCTFail("all five sections present") }

        // The whole point of this score is that it is checkable by hand.
        let byHand = SleepSection.allCases.reduce(0.0) { acc, sec in
            acc + Double(sec.weight) * Double(s.sections[sec] ?? 0)
        }
        XCTAssertEqual(Double(overall), byHand.rounded(), accuracy: 1)
    }

    func testWeightsSumToOne() {
        let total = SleepSection.allCases.reduce(0.0) { $0 + Double($1.weight) }
        XCTAssertEqual(total, 1.0, accuracy: 0.0001)
    }

    func testRegularityAndDurationCarryTheMostWeight() {
        // The evidence ranking must be visible in the model, not just the docs.
        XCTAssertEqual(SleepSection.timing.weight, 0.25, accuracy: 0.0001)
        XCTAssertEqual(SleepSection.duration.weight, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(SleepSection.timing.weight, SleepSection.continuity.weight)
        XCTAssertGreaterThan(SleepSection.duration.weight, SleepSection.breathing.weight)
    }

    func testAbsentSectionRenormalisesRatherThanScoringZero() {
        // No trailing nights yet, so there is no regularity index. Treating
        // that as a zero would punish the user for the app's own youth.
        var input = settled()
        input.regularityIndex = nil
        let s = SleepScore.compute(input)

        XCTAssertNil(s.sections[.timing])
        XCTAssertEqual(s.sections.count, 4)

        let present = SleepScore.compute(settled())
        XCTAssertGreaterThan(s.overall ?? 0, (present.overall ?? 0) - 25,
                             "a missing section must not drag the night down")
    }

    func testShortNightScoresLowerOnDurationOnly() {
        var input = settled()
        input.asleepSec = 5 * 3600
        let s = SleepScore.compute(input)

        XCTAssertLessThan(s.sections[.duration] ?? 100, 50)
        XCTAssertEqual(s.sections[.timing], SleepScore.compute(settled()).sections[.timing],
                       "duration must not leak into the timing section")
    }

    func testLateShallowNadirScoresLowerOnAutonomic() {
        var input = settled()
        input.hrNadirDip = 7            // barely settled
        input.hrNadirFraction = 0.78    // and very late
        let s = SleepScore.compute(input)

        XCTAssertLessThan(s.sections[.autonomic] ?? 100,
                          SleepScore.compute(settled()).sections[.autonomic] ?? 0)
    }

    func testRequiresTwoSectionsForAnOverall() {
        var input = settled()
        input.regularityIndex = nil
        input.longestUnbrokenSec = nil
        input.hrNadirDip = nil
        input.steadyFraction = nil
        let s = SleepScore.compute(input)

        XCTAssertEqual(s.sections.count, 1)
        XCTAssertNil(s.overall, "one section is not a night score")
    }

    func testArithmeticStringShowsEveryPresentSection() {
        let s = SleepScore.compute(settled())
        let line = s.arithmetic

        XCTAssertTrue(line.contains("25%"), "weights must be visible: \(line)")
        for section in SleepSection.allCases {
            XCTAssertTrue(line.lowercased().contains(section.name.lowercased()),
                          "\(section.name) missing from: \(line)")
        }
    }
}
