import XCTest
@testable import Wythin

final class SleepScoreTests: XCTestCase {

    /// A settled night: on-time, long enough, unbroken, a deep well-placed
    /// heart-rate nadir, and steady breathing.
    private func settled() -> SleepScoreInput {
        SleepScoreInput(bedtimeSDMin: 30,
                        asleepSec: 7.33 * 3600,
                        needSec: 7.75 * 3600,
                        wakeBouts: 3,
                        longestUnbrokenSec: 2.8 * 3600,
                        hrNadirDip: 14,
                        hrNadirFraction: 0.45,
                        quietRMSSD: 52, quietRMSSDBaseline: 50,
                        quietDC: 7.2, quietDCBaseline: 7.0,
                        steadyFraction: 0.965)
    }

    // MARK: - Autonomic: vagal tone against this sleeper, not a population band

    private func autonomic(_ f: (inout SleepScoreInput) -> Void) -> Int? {
        var input = settled()
        f(&input)
        return SleepScore.compute(input).sections[.autonomic]
    }

    /// The old ramp was absolute — 22 ms scored 0, 62 scored 100 — on the most
    /// trait-variable number the app records. RMSSD falls steeply with age, so
    /// that scale marked a healthy sixty-year-old down for being sixty. What
    /// matters is the night against their own recent nights.
    func testTheSameRMSSDScoresDifferentlyForDifferentSleepers() {
        let athlete = autonomic { $0.quietRMSSD = 40; $0.quietRMSSDBaseline = 80 }
        let older   = autonomic { $0.quietRMSSD = 40; $0.quietRMSSDBaseline = 26 }
        guard let athlete, let older else { return XCTFail("both are scoreable") }
        XCTAssertLessThan(athlete, older,
                          "40 ms is half the athlete's usual and well above the older sleeper's")
    }

    func testANightAtYourOwnMedianSitsMidScale() {
        let atUsual = autonomic {
            $0.hrNadirDip = nil            // isolate the vagal parts
            $0.quietRMSSD = 44; $0.quietRMSSDBaseline = 44
            $0.quietDC = 6.0;   $0.quietDCBaseline = 6.0
        }
        // Nadir absent means the section is absent entirely — depth is what
        // opens it. Check the pair through a present nadir instead.
        XCTAssertNil(atUsual, "no nadir, no autonomic section")

        let usual = autonomic {
            $0.quietRMSSD = 44; $0.quietRMSSDBaseline = 44
            $0.quietDC = 6.0;   $0.quietDCBaseline = 6.0
        }
        let better = autonomic {
            $0.quietRMSSD = 57; $0.quietRMSSDBaseline = 44
            $0.quietDC = 7.8;   $0.quietDCBaseline = 6.0
        }
        guard let usual, let better else { return XCTFail("scoreable") }
        XCTAssertGreaterThan(better, usual, "a night above your usual scores above it")
    }

    /// A new sleeper has no baseline. The vagal parts drop out and the section
    /// is scored on what is measurable, rather than marking someone down for
    /// having no history.
    func testWithoutABaselineTheSectionIsStillScoredOnWhatIsThere() {
        let noHistory = autonomic {
            $0.quietRMSSDBaseline = nil
            $0.quietDCBaseline = nil
        }
        XCTAssertNotNil(noHistory, "depth and placement still describe the night")
        XCTAssertEqual(noHistory, autonomic {
            $0.quietRMSSD = nil; $0.quietRMSSDBaseline = nil
            $0.quietDC = nil;    $0.quietDCBaseline = nil
        }, "a value with nothing to compare it to contributes nothing either way")
    }

    /// DC is the better-evidenced of the pair — in HypnoLaus it survived FDR
    /// correction where every time-domain HRV parameter did not — so it should
    /// move the section further than RMSSD does.
    func testDeclarationCapacityCarriesMoreWeightThanRMSSD() {
        let dcHigh = autonomic { $0.quietDC = 9.0; $0.quietDCBaseline = 6.0 }
        let rmssdHigh = autonomic { $0.quietRMSSD = 66; $0.quietRMSSDBaseline = 44 }
        guard let dcHigh, let rmssdHigh else { return XCTFail("scoreable") }
        XCTAssertGreaterThan(dcHigh, rmssdHigh,
                             "the same proportional lift counts for more through DC")
    }

    func testSectionsAndOverallAreTheWeightedMean() {
        let s = SleepScore.compute(settled())

        XCTAssertEqual(s.sections.count, 4)
        guard let overall = s.overall else { return XCTFail("all four sections present") }

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
        // Four sections, equal quarters, summing to one. Equal because the
        // exchange rate between them is not published — see SleepSection.
        XCTAssertEqual(SleepSection.allCases.count, 4)
        for section in SleepSection.allCases {
            XCTAssertEqual(section.weight, 0.25, accuracy: 0.0001, "\(section.name)")
        }
        XCTAssertEqual(SleepSection.allCases.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 0.0001)
        XCTAssertFalse(SleepSection.allCases.contains { $0.name == "Breathing" },
                       "breath steadiness is an input to continuity, not an axis of its own")
    }

    func testAbsentSectionRenormalisesRatherThanScoringZero() {
        // No trailing nights yet, so there is no regularity index. Treating
        // that as a zero would punish the user for the app's own youth.
        var input = settled()
        input.bedtimeSDMin = nil
        let s = SleepScore.compute(input)

        XCTAssertNil(s.sections[.timing])
        XCTAssertEqual(s.sections.count, 3)

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
        input.bedtimeSDMin = nil
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
