import XCTest
@testable import Wythin

/// Four layers standing between "your recovery metrics look bad" and telling
/// someone mid-workout to go and breathe slowly.
///
/// The server prompt states the rule these encode: a high or rising HR with
/// GOOD recovery metrics is high ENERGY, not stress.
final class ExerciseVetoTests: XCTestCase {

    // MARK: Layer 1 — motion floor

    func testSedentaryWindowPassesTheMotionFloor() {
        XCTAssertFalse(ExerciseVeto.exceedsMotionFloor(NudgeFixture.signals()))
    }

    func testRunningFailsTheMotionFloor() {
        XCTAssertTrue(ExerciseVeto.exceedsMotionFloor(NudgeFixture.running()))
    }

    /// A single burst anywhere in the window disqualifies it — the rule is on
    /// the window maximum, not its mean, so standing up mid-window counts.
    func testASingleMotionBurstDisqualifiesTheWindow() {
        let s = NudgeFixture.signals(motion: { i in i == 30 ? 80 : 4 })
        XCTAssertTrue(ExerciseVeto.exceedsMotionFloor(s))
    }

    // MARK: Layer 2 — post-exertion lockout

    func testLockoutHoldsImmediatelyAfterExertion() {
        let now = Date()
        XCTAssertTrue(ExerciseVeto.isWithinLockout(now: now,
                                                   lastActiveAt: now.addingTimeInterval(-600)))
    }

    func testLockoutHasExpiredAfterFortyFiveMinutes() {
        let now = Date()
        XCTAssertFalse(ExerciseVeto.isWithinLockout(now: now,
                                                    lastActiveAt: now.addingTimeInterval(-46 * 60)))
    }

    func testLockoutDoesNotApplyWithoutRecentExertion() {
        XCTAssertFalse(ExerciseVeto.isWithinLockout(now: Date(), lastActiveAt: nil))
    }

    // MARK: Layer 3 — energy, not stress

    /// HR climbing while recovery holds is high energy. Do not nudge.
    func testRisingHeartRateWithIntactRecoveryReadsAsEnergy() {
        let s = NudgeFixture.signals(hr: { i in i < 30 ? 60 : 85 })   // recovery flat
        XCTAssertTrue(ExerciseVeto.isEnergyNotStress(s))
    }

    /// HR climbing while recovery collapses is the real thing.
    func testRisingHeartRateWithCollapsingRecoveryIsNotVetoed() {
        let s = NudgeFixture.signals(hr:    { i in i < 30 ? 60 : 85 },
                                     rmssd: { i in i < 12 ? 50 : (i >= 48 ? 18 : 30) })
        XCTAssertFalse(ExerciseVeto.isEnergyNotStress(s))
    }

    func testFlatHeartRateIsNotEnergy() {
        XCTAssertFalse(ExerciseVeto.isEnergyNotStress(NudgeFixture.signals()))
    }

    /// Falling RSA breaks the "recovery is intact" claim even when the dz terms
    /// look acceptable.
    func testFallingRSABreaksTheEnergyReading() {
        let s = NudgeFixture.signals(hr:  { i in i < 30 ? 60 : 85 },
                                     rsa: { i in i < 30 ? 45 : 20 })
        XCTAssertFalse(ExerciseVeto.isEnergyNotStress(s))
    }

    // MARK: Layer 4 — HR ceiling

    /// This layer exists for machine work, where chest ACC stays low and layer 1
    /// never fires.
    func testStationaryBikeIsCaughtByTheHeartRateCeiling() {
        let s = NudgeFixture.stationaryBike()
        XCTAssertFalse(ExerciseVeto.exceedsMotionFloor(s), "layer 1 is expected to miss this")
        XCTAssertTrue(ExerciseVeto.exceedsHRCeiling(s, baseline: NudgeFixture.baseline()))
    }

    func testRestingHeartRateIsBelowTheCeiling() {
        XCTAssertFalse(ExerciseVeto.exceedsHRCeiling(NudgeFixture.signals(),
                                                     baseline: NudgeFixture.baseline()))
    }

    func testCeilingIsPersonalNotAbsolute() {
        let s = NudgeFixture.signals(hr: { _ in 100 })
        // Resting 58 → ceiling 93: 100 is over.
        XCTAssertTrue(ExerciseVeto.exceedsHRCeiling(s, baseline: NudgeFixture.baseline(restingHR: 58)))
        // Resting 75 → ceiling 110: the same 100 is under.
        XCTAssertFalse(ExerciseVeto.exceedsHRCeiling(s, baseline: NudgeFixture.baseline(restingHR: 75)))
    }

    // MARK: Composite

    func testARunIsVetoedOverall() {
        XCTAssertTrue(ExerciseVeto.vetoes(NudgeFixture.running(),
                                          baseline: NudgeFixture.baseline(),
                                          now: Date(), lastActiveAt: nil))
    }

    func testStationaryCyclingIsVetoedOverall() {
        XCTAssertTrue(ExerciseVeto.vetoes(NudgeFixture.stationaryBike(),
                                          baseline: NudgeFixture.baseline(),
                                          now: Date(), lastActiveAt: nil))
    }

    func testAGenuineSedentaryWithdrawalIsNotVetoed() {
        XCTAssertFalse(ExerciseVeto.vetoes(NudgeFixture.withdrawing(),
                                           baseline: NudgeFixture.baseline(),
                                           now: Date(), lastActiveAt: nil))
    }
}
