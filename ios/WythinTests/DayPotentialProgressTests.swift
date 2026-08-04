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
}
