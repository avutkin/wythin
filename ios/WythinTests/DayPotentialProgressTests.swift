import XCTest
@testable import Wythin

/// The Day Potential strip's presentation-only logic: the display floor, the
/// crown ladder, and the copy that nudges toward the next crown. All three
/// are pure, so they are pinned here without a store or a SwiftData context.
final class DayPotentialProgressTests: XCTestCase {

    // MARK: - Display floor

    private func result(score: Int) -> PotentialResult {
        PotentialResult(
            score: score,
            band: PotentialBand.forScore(score),
            components: PotentialComponents(lnRMSSDz: 0, dcZ: 0, restingHRz: 0),
            penalties: PotentialPenalties(stability: 0, fragmentation: 0, organization: 0),
            saturated: false)
    }

    /// The regression this whole item exists to prevent: a hard morning must
    /// not display "0" beside the band word. Also pins the other half of the
    /// contract — the model itself is never touched by the floor.
    func testZeroScoreRoundTripsAsZeroInModelButDisplaysAsOne() {
        let r = result(score: 0)
        XCTAssertEqual(r.score, 0, "the stored/model score must stay exactly 0")
        XCTAssertEqual(DayPotentialDisplay.score(for: r), 1, "the displayed score must never read 0")
    }

    func testNoResultDisplaysNilNotZero() {
        XCTAssertNil(DayPotentialDisplay.score(for: nil))
    }

    func testScoreAboveFloorPassesThroughUnchanged() {
        XCTAssertEqual(DayPotentialDisplay.score(for: result(score: 45)), 45)
        XCTAssertEqual(DayPotentialDisplay.score(for: result(score: 1)), 1)
    }

    // MARK: - Crown ladder: raw maths (worked examples from the spec)

    func testZeroMorningsHasNoCrownsAtAll() {
        let c = CrownLadder.counts(forMorningCount: 0)
        XCTAssertEqual(c, CrownLadder.Counts(greens: 0, reds: 0, yellows: 0, hasWhite: false))
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 0), [])
    }

    func testElevenMorningsIsOneYellowAndOneWhite() {
        let c = CrownLadder.counts(forMorningCount: 11)
        XCTAssertEqual(c, CrownLadder.Counts(greens: 0, reds: 0, yellows: 1, hasWhite: true))
    }

    func test587MorningsIsFiveGreenZeroRedThreeYellowOneWhite() {
        let c = CrownLadder.counts(forMorningCount: 587)
        XCTAssertEqual(c, CrownLadder.Counts(greens: 5, reds: 0, yellows: 3, hasWhite: true))
    }

    // MARK: - Crown ladder: boundaries

    /// One away from a crown: the current week has six of its seven
    /// mornings, so only the white (in-progress) crown shows.
    func testSixMorningsShowsOnlyTheWhiteCrown() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 6), [CrownToken(.white)])
    }

    /// Exactly seven: one full week, no partial week left over, so the white
    /// crown must NOT appear.
    func testSevenMorningsIsExactlyOneYellowNoWhite() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 7), [CrownToken(.yellow)])
    }

    /// Four completed weeks (28 mornings) roll the four yellows into one red,
    /// landing on an exact multiple with no white crown.
    func testTwentyEightMorningsIsExactlyOneRedNoWhite() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 28), [CrownToken(.red)])
    }

    /// Sixteen completed weeks (112 mornings) roll the four reds into one
    /// green, again landing exactly with no white crown.
    func testOneHundredTwelveMorningsIsExactlyOneGreenNoWhite() {
        XCTAssertEqual(CrownLadder.tokens(forMorningCount: 112), [CrownToken(.green)])
    }

    /// One morning past a completed-week boundary puts the white crown back.
    func testOneMorningPastAWeekBoundaryShowsWhiteAgain() {
        let tokens = CrownLadder.tokens(forMorningCount: 8)
        XCTAssertTrue(tokens.contains(CrownToken(.white)))
    }

    // MARK: - Crown ladder: overflow

    /// At the collapse threshold, greens still draw individually — collapse
    /// must not trigger a step early.
    func testThreeGreensStillDrawIndividually() {
        // 3 greens, 0 red, 0 yellow, no white: 48 completed weeks, 336 mornings.
        let tokens = CrownLadder.tokens(forMorningCount: 336)
        XCTAssertEqual(tokens, [CrownToken(.green), CrownToken(.green), CrownToken(.green)])
    }

    /// One green past the threshold collapses to a single crown carrying a
    /// count, so the row can never grow unbounded after years of use.
    func testFourGreensCollapseToOneCrownWithACount() {
        // 4 greens, 0 red, 0 yellow, no white: 64 completed weeks, 448 mornings.
        let tokens = CrownLadder.tokens(forMorningCount: 448)
        XCTAssertEqual(tokens, [CrownToken(.green, overflowCount: 4)])
    }

    /// The 587-morning worked example also exercises overflow together with
    /// the other tiers: five greens collapse, yellows and white draw normally.
    func test587MorningsCollapsesGreensButDrawsOtherTiersIndividually() {
        let tokens = CrownLadder.tokens(forMorningCount: 587)
        XCTAssertEqual(tokens, [
            CrownToken(.green, overflowCount: 5),
            CrownToken(.yellow), CrownToken(.yellow), CrownToken(.yellow),
            CrownToken(.white),
        ])
    }
}
