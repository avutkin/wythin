import XCTest
@testable import Wythin

@MainActor
final class DayPotentialPreparationTests: XCTestCase {
    func testFailedBackfillRemainsRetryable() async {
        let store = DayPotentialStore()
        let failed = await store.ensureBackfill { false }
        XCTAssertFalse(failed)
        var retries = 0
        let recovered = await store.ensureBackfill { retries += 1; return true }
        XCTAssertTrue(recovered)
        XCTAssertEqual(retries, 1)
    }

    func testPressureCancelsViewOwnedBackfillAndBlocksDuplicateForegroundRetry() async {
        let store = DayPotentialStore()
        var release: CheckedContinuation<Void, Never>?
        var canceled = false
        var calls = 0
        let entered = expectation(description: "view requested backfill")
        let request = Task {
            await store.ensureBackfill {
                calls += 1
                await withCheckedContinuation { release = $0; entered.fulfill() }
                canceled = Task.isCancelled
                return true
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        store.suspendUntilNextForeground()
        store.setForeground(true)
        let overlapping = await store.ensureBackfill { calls += 1; return true }
        XCTAssertFalse(overlapping)
        release?.resume()
        let completed = await request.value
        XCTAssertFalse(completed)
        XCTAssertTrue(canceled)
        let suspended = await store.ensureBackfill { calls += 1; return true }
        XCTAssertFalse(suspended)
        XCTAssertEqual(calls, 1)
        store.setForeground(false)
        let background = await store.ensureBackfill { calls += 1; return true }
        XCTAssertFalse(background)
        store.setForeground(true)
        let retried = await store.ensureBackfill { calls += 1; return true }
        XCTAssertTrue(retried)
        XCTAssertEqual(calls, 2)
    }

    func testCancellationDuringBackfillPreventsRefreshAndLeavesNextAttemptUsable() async {
        let store = DayPotentialStore()
        let entered = expectation(description: "backfill started")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let task = Task {
            await store.ensureBackfill {
                calls += 1
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.fulfill()
                }
                return true
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        release?.resume()
        let mayRefresh = await task.value
        XCTAssertFalse(mayRefresh, "A canceled caller must not read/write anchors or generate UI insights")
        let retried = await store.ensureBackfill { calls += 1; return true }
        XCTAssertTrue(retried)
        XCTAssertEqual(calls, 2, "Canceled preparation must not mark a later refresh complete")
        let cached = await store.ensureBackfill { calls += 1; return true }
        XCTAssertTrue(cached)
        XCTAssertEqual(calls, 2)
    }

    func testAlreadyCanceledRefreshDoesNotBeginBackfill() async {
        let store = DayPotentialStore()
        var calls = 0
        let task = Task { await store.ensureBackfill { calls += 1; return true } }
        task.cancel()
        let mayRefresh = await task.value
        XCTAssertFalse(mayRefresh)
        XCTAssertEqual(calls, 0)
    }
}

/// The state machine behind the strip's headline. Pure, so it can be tested
/// without a SwiftData context or an AppEnvironment.
final class DayPotentialStateTests: XCTestCase {

    private func anchor(hour: Double = 7, late: Bool = false) -> AnchorReading {
        AnchorReading(startedAt: Date(), durationSec: 300, hour: hour,
                      lnRMSSD: 3.6, dc: 7.5, restingHR: 60, pip: 40, dfa1: 1.0,
                      breathBPM: 13, late: late, motionKnown: true, confidence: .high)
    }

    private func baseline(n: Int) -> AnchorBaseline {
        AnchorBaseline(
            lnRMSSD:   BaselineStat(mean: 3.6, sd: 0.2, n: n),
            restingHR: BaselineStat(mean: 60, sd: 4, n: n),
            dc:        BaselineStat(mean: 7.5, sd: 1, n: n),
            pip:       BaselineStat(mean: 40, sd: 5, n: n),
            dfa1Median: 1.0,
            cv7:       nil,
            cv7Stat:   nil,
            medianHour: 7,
            anchorCount: n,
            hourMatched: true,
            provisional: n < AnchorBaseline.firmAnchors)
    }

    private func result(score: Int = 50) -> PotentialResult {
        PotentialResult(
            score: score,
            band: PotentialBand.forScore(score),
            components: PotentialComponents(lnRMSSDz: 0, dcZ: 0, restingHRz: 0),
            penalties: PotentialPenalties(stability: 0, fragmentation: 0, organization: 0),
            saturated: false)
    }

    // MARK: - Derivation

    func testNoAnchorWaitsForStillness() {
        let s = DayPotentialStore.State.derive(anchor: nil, baseline: baseline(n: 10), result: nil)
        XCTAssertEqual(s, .waitingForStillness)
    }

    func testAnchorWithNoPriorHistoryIsFirstMorning() {
        let s = DayPotentialStore.State.derive(anchor: anchor(), baseline: nil, result: nil)
        XCTAssertEqual(s, .firstMorning)
    }

    func testFewPriorAnchorsScoreProvisionally() {
        let s = DayPotentialStore.State.derive(
            anchor: anchor(), baseline: baseline(n: 3), result: result())
        XCTAssertEqual(s, .scored(provisional: true))
    }

    func testFirmBaselineScoresOutright() {
        let s = DayPotentialStore.State.derive(
            anchor: anchor(), baseline: baseline(n: 10), result: result())
        XCTAssertEqual(s, .scored(provisional: false))
    }

    /// The bug this replaces: an anchor too far from the usual hour made
    /// `evaluate` return nil, which was reported as "waiting for a still
    /// moment" while the row below it displayed the anchor that had been found.
    func testUnscorableAnchorIsNotComparableRatherThanMissing() {
        let s = DayPotentialStore.State.derive(
            anchor: anchor(hour: 15, late: true), baseline: baseline(n: 10), result: nil)
        XCTAssertEqual(s, .notComparable)
    }

    // MARK: - Headline

    func testHeadlineNamesTheBandOnceFirm() {
        XCTAssertEqual(DayPotentialStore.State.scored(provisional: false).headline(band: .good),
                       "TODAY'S POTENTIAL · GOOD RESERVES")
    }

    func testProvisionalHeadlineMarksTheReadAsEarly() {
        let h = DayPotentialStore.State.scored(provisional: true).headline(band: .good)
        XCTAssertEqual(h, "TODAY'S POTENTIAL · GOOD RESERVES · EARLY DAYS")
    }

    func testWaitingAndFirstMorningReadDifferently() {
        XCTAssertEqual(DayPotentialStore.State.waitingForStillness.headline(band: nil),
                       "TODAY'S POTENTIAL · WAITING FOR A STILL MOMENT")
        XCTAssertEqual(DayPotentialStore.State.firstMorning.headline(band: nil),
                       "MORNING READ · FIRST ONE LOGGED")
    }

    func testNotComparableSaysSoPlainly() {
        XCTAssertEqual(DayPotentialStore.State.notComparable.headline(band: nil),
                       "LATER READ · NOT COMPARABLE TODAY")
    }

    // MARK: - Score visibility

    func testOnlyScoredStatesShowANumber() {
        XCTAssertTrue(DayPotentialStore.State.scored(provisional: true).showsScore)
        XCTAssertTrue(DayPotentialStore.State.scored(provisional: false).showsScore)
        XCTAssertFalse(DayPotentialStore.State.waitingForStillness.showsScore)
        XCTAssertFalse(DayPotentialStore.State.firstMorning.showsScore)
        XCTAssertFalse(DayPotentialStore.State.notComparable.showsScore)
    }
}
