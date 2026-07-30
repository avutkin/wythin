import XCTest
@testable import Wythin

/// Each trigger owns a distinct primary metric, so a firing case for one is a
/// near-miss for the others. Every numeric clause gets a near-miss test — that
/// is where a rule silently widens.
final class NudgeTriggersTests: XCTestCase {

    private let now = Date()

    private func ctx(still: TimeInterval? = nil,
                     load: TimeInterval? = nil,
                     active: TimeInterval? = nil) -> NudgeContext {
        NudgeContext(now: now,
                     stillSince:   still.map  { now.addingTimeInterval(-$0) },
                     loadSince:    load.map   { now.addingTimeInterval(-$0) },
                     lastActiveAt: active.map { now.addingTimeInterval(-$0) })
    }

    private func fired(_ s: NudgeSignals, _ c: NudgeContext,
                       baseline: AnchorBaseline? = nil) -> [NudgeTriggerID] {
        NudgeTriggers.evaluate(s, baseline: baseline ?? NudgeFixture.baseline(), context: c)
    }

    /// RMSSD sliding 50 → 18 across the window: the balance dial climbs through
    /// the sympathetic reference line while recovery drops well over one
    /// personal SD.
    private func withdrawal(from: Float = 50, to: Float = 18) -> NudgeSignals {
        NudgeFixture.signals(now: now, rmssd: { i in from - (from - to) * Float(i) / 59 })
    }

    // MARK: - D1 vagal withdrawal

    func testFiresWhenArousalClimbsAsRecoveryFalls() {
        XCTAssertTrue(fired(withdrawal(), ctx()).contains(.vagalWithdrawal))
    }

    /// The dial must actually reach the sympathetic line. A slide that ends in
    /// the balanced zone is not a nudge.
    func testDoesNotFireWhenTheDialStopsShortOfTheSympatheticLine() {
        // RMSSD 50 → 30 ends at 100×40/70 = 57, under the 65 line.
        XCTAssertFalse(fired(withdrawal(to: 30), ctx()).contains(.vagalWithdrawal))
    }

    func testDoesNotFireWhenRecoveryHasBarelyMoved() {
        // Already low and staying low: end is past 65 but there is no change.
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 20 })
        XCTAssertFalse(fired(s, ctx()).contains(.vagalWithdrawal))
    }

    /// Slow paced breathing is inherently vagal — never call it a stress state.
    func testDoesNotFireWhileTheUserIsAlreadyDoingBreathwork() {
        let s = NudgeFixture.signals(now: now,
                                     rmssd: { i in 50 - 32 * Float(i) / 59 },
                                     breath: { _ in 6 })
        XCTAssertFalse(fired(s, ctx()).contains(.vagalWithdrawal))
    }

    func testDoesNotFireDuringExertion() {
        XCTAssertFalse(fired(NudgeFixture.running(now: now), ctx()).contains(.vagalWithdrawal))
    }

    func testDoesNotFireInsideThePostExertionLockout() {
        XCTAssertFalse(fired(withdrawal(), ctx(active: 10 * 60)).contains(.vagalWithdrawal))
    }

    func testFiresOnceTheLockoutHasCleared() {
        XCTAssertTrue(fired(withdrawal(), ctx(active: 50 * 60)).contains(.vagalWithdrawal))
    }

    // MARK: - D2 sustained load

    private func underLoad() -> NudgeSignals {
        NudgeFixture.signals(now: now,
                             rmssd: { i in 50 - 20 * Float(i) / 59 },
                             dfa1:  { i in 1.0 - 0.25 * Float(i) / 59 })
    }

    func testFiresAfterALongStretchWithDriftingOrganisation() {
        XCTAssertTrue(fired(underLoad(), ctx(load: 100 * 60)).contains(.sustainedLoad))
    }

    func testDoesNotFireBeforeTheDurationGate() {
        XCTAssertFalse(fired(underLoad(), ctx(load: 60 * 60)).contains(.sustainedLoad))
    }

    func testDoesNotFireWithoutAnOpenLoadStretch() {
        XCTAssertFalse(fired(underLoad(), ctx()).contains(.sustainedLoad))
    }

    /// Duration alone is not enough — organisation has to be drifting too,
    /// otherwise this fires on every long calm morning.
    func testDoesNotFireWhenOrganisationHoldsUp() {
        let s = NudgeFixture.signals(now: now,
                                     rmssd: { i in 50 - 20 * Float(i) / 59 },
                                     dfa1:  { _ in 1.05 })
        XCTAssertFalse(fired(s, ctx(load: 100 * 60)).contains(.sustainedLoad))
    }

    func testDoesNotFireWhenRecoveryIsSteady() {
        let s = NudgeFixture.signals(now: now,
                                     rmssd: { _ in 44 },
                                     dfa1:  { i in 1.0 - 0.25 * Float(i) / 59 })
        XCTAssertFalse(fired(s, ctx(load: 100 * 60)).contains(.sustainedLoad))
    }

    // MARK: - D3 stuck still

    func testFiresAfterALongSedentaryStretch() {
        XCTAssertTrue(fired(NudgeFixture.signals(now: now), ctx(still: 60 * 60)).contains(.stuckStill))
    }

    func testDoesNotFireBeforeTheSedentaryGate() {
        XCTAssertFalse(fired(NudgeFixture.signals(now: now), ctx(still: 30 * 60)).contains(.stuckStill))
    }

    func testDoesNotFireWithoutAStillnessStretch() {
        XCTAssertFalse(fired(NudgeFixture.signals(now: now), ctx()).contains(.stuckStill))
    }

    // MARK: - D4 acute spike

    /// HR jumping without movement is the discriminator: exertion moves the
    /// chest, a stress response does not.
    private func spike() -> NudgeSignals {
        NudgeFixture.signals(
            now: now,
            hr:  { i in i < 40 ? 62 : 65 + 20 * Float(i - 40) / 19 },
            rsa: { i in i < 40 ? 35 : 30 - 15 * Float(i - 40) / 19 })
    }

    func testFiresWhenHeartRateJumpsWithoutMovement() {
        XCTAssertTrue(fired(spike(), ctx()).contains(.acuteSpike))
    }

    func testDoesNotFireWhenTheSameJumpComesWithMovement() {
        let s = NudgeFixture.signals(
            now: now,
            hr:     { i in i < 40 ? 62 : 65 + 20 * Float(i - 40) / 19 },
            rsa:    { i in i < 40 ? 35 : 30 - 15 * Float(i - 40) / 19 },
            motion: { i in i < 40 ? 5 : 90 })
        XCTAssertFalse(fired(s, ctx()).contains(.acuteSpike))
    }

    func testDoesNotFireOnASmallDrift() {
        let s = NudgeFixture.signals(
            now: now,
            hr:  { i in i < 40 ? 62 : 64 + 4 * Float(i - 40) / 19 },   // +6 bpm
            rsa: { i in i < 40 ? 35 : 30 - 15 * Float(i - 40) / 19 })
        XCTAssertFalse(fired(s, ctx()).contains(.acuteSpike))
    }

    /// Without RSA corroboration a rise is just a rise.
    func testDoesNotFireWhenRSAHolds() {
        let s = NudgeFixture.signals(
            now: now,
            hr:  { i in i < 40 ? 62 : 65 + 20 * Float(i - 40) / 19 },
            rsa: { _ in 35 })
        XCTAssertFalse(fired(s, ctx()).contains(.acuteSpike))
    }

    // MARK: - F1 focus window

    /// Calm, steady, well-organised and clean: RMSSD comfortably above the
    /// person's own norm with the dial in the parasympathetic zone.
    private func clearWindow() -> NudgeSignals {
        NudgeFixture.signals(now: now, rmssd: { _ in 55 })
    }

    func testFiresWhenEveryConditionHolds() {
        XCTAssertTrue(fired(clearWindow(), ctx()).contains(.focusWindow))
    }

    func testDoesNotFireWhenTheDialIsMerelyOrdinary() {
        XCTAssertFalse(fired(NudgeFixture.signals(now: now), ctx()).contains(.focusWindow))
    }

    /// Calm but disorganised is not a focus window.
    func testDoesNotFireWhenOrganisationIsDrifting() {
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 55 }, dfa1: { _ in 0.7 })
        XCTAssertFalse(fired(s, ctx()).contains(.focusWindow))
    }

    func testDoesNotFireWhenOrganisationIsRigid() {
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 55 }, dfa1: { _ in 1.4 })
        XCTAssertFalse(fired(s, ctx()).contains(.focusWindow))
    }

    /// The claim must not be derivable from a noisy read.
    func testDoesNotFireWhenAnySampleFailsTheQualityGate() {
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 55 },
                                     quality: { i in i == 20 ? 0.6 : 0.98 })
        XCTAssertFalse(fired(s, ctx()).contains(.focusWindow))
    }

    func testDoesNotFireWhileMoving() {
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 55 }, motion: { _ in 40 })
        XCTAssertFalse(fired(s, ctx()).contains(.focusWindow))
    }

    /// Paced breathing produces the same calm signature artificially.
    func testDoesNotFireDuringPacedBreathing() {
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 55 }, breath: { _ in 6 })
        XCTAssertFalse(fired(s, ctx()).contains(.focusWindow))
    }

    /// Calm in absolute terms but below this person's own norm.
    func testDoesNotFireBelowThePersonalNorm() {
        let high = NudgeFixture.baseline(restingHR: 58)
        let s = NudgeFixture.signals(now: now, rmssd: { _ in 55 })
        // Baseline mean lnRMSSD 4.6 ≈ RMSSD 100, so 55 sits well below normal.
        let raised = AnchorBaseline(
            lnRMSSD: BaselineStat(mean: 4.6, sd: 0.2, n: 200),
            restingHR: high.restingHR, dc: high.dc, pip: high.pip,
            dfa1Median: 1.0, cv7: nil, cv7Stat: nil,
            medianHour: 8, anchorCount: 200, hourMatched: true, provisional: false)
        XCTAssertFalse(fired(s, ctx(), baseline: raised).contains(.focusWindow))
    }

    // MARK: - Cross-cutting

    func testNothingFiresWithoutABaseline() {
        XCTAssertTrue(NudgeTriggers.evaluate(withdrawal(), baseline: nil, context: ctx()).isEmpty)
    }

    func testACalmOrdinaryWindowFiresNothing() {
        XCTAssertTrue(fired(NudgeFixture.signals(now: now), ctx()).isEmpty)
    }
}
