import XCTest
import SwiftData
@testable import Wythin

/// The backfill is the only code that deletes persisted user data
/// unconditionally, runs exactly once per install, and has no undo — so what it
/// keeps matters as much as what it rebuilds.
final class AnchorBackfillTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults:  UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let schema = Schema([HRVSample.self, HRVSession.self, DailyAnchor.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container  = try! ModelContainer(for: schema, configurations: [config])
        suiteName  = "AnchorBackfillTests-\(UUID().uuidString)"
        defaults   = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults  = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Local start-of-day `back` days ago.
    private func day(_ back: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: .now))!
    }

    /// Inserts a rest of `count` samples at `spacing` seconds, starting at
    /// `hour` on `day`. `sdnn`/`rmssd` are set because `MetricsQualityFilter`
    /// drops anything that looks like an off-body strap before the detector
    /// ever sees it.
    private func insertRest(day: Date, hour: Int, count: Int, spacing: Double,
                            hr: Float, motion: Float?, into ctx: ModelContext) {
        let start = day.addingTimeInterval(Double(hour) * 3600)
        for i in 0..<count {
            ctx.insert(HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i) * spacing),
                                 meanBPM: hr, vti: 3.6, rmssd: 36.6, sdnn: 45,
                                 dc: 7.5, pip: 42, dfa1: 1.0, breathBPM: 13, motion: motion,
                                 signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2))
        }
    }

    /// A stored anchor as the old detector would have left it — the marker
    /// value is `restingHR`, so a recompute is visible as a change to 60.
    private func insertAnchor(day: Date, restingHR: Float, into ctx: ModelContext) {
        ctx.insert(DailyAnchor(from: AnchorReading(
            startedAt: day.addingTimeInterval(7 * 3600), durationSec: 600, hour: 7,
            lnRMSSD: 3.0, dc: 7.5, restingHR: restingHR, pip: 42, dfa1: 1.0, breathBPM: 13,
            late: false, motionKnown: true, confidence: .high)))
    }

    /// Read through a fresh context — the backfill writes on its own.
    private func anchors(on day: Date? = nil) -> [DailyAnchor] {
        let all = (try? ModelContext(container).fetch(FetchDescriptor<DailyAnchor>())) ?? []
        guard let day else { return all }
        return all.filter { $0.day == day }
    }

    // MARK: - What it keeps and what it rebuilds

    func testKeepsTheAnchorOfADayWhoseSamplesAreGone() async {
        let ctx = ModelContext(container)
        insertRest(day: day(5), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        insertAnchor(day: day(10), restingHR: 99, into: ctx)   // no samples for that day
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)

        XCTAssertEqual(anchors(on: day(10)).first?.restingHR ?? 0, 99, accuracy: 0.001,
                       "there is nothing to rebuild it from — a stale anchor beats no anchor")
    }

    func testRecomputesADayThatStillQualifies() async {
        let ctx = ModelContext(container)
        insertRest(day: day(5), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        insertAnchor(day: day(5), restingHR: 99, into: ctx)
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)

        let rebuilt = anchors(on: day(5))
        XCTAssertEqual(rebuilt.count, 1, "delete and insert, not insert alongside")
        XCTAssertEqual(rebuilt.first?.restingHR ?? 0, 60, accuracy: 0.001)
    }

    func testDropsTheAnchorOfADayThatNoLongerQualifies() async {
        let ctx = ModelContext(container)
        // Worn and recording, but moving throughout — every sample is rejected.
        insertRest(day: day(4), hour: 7, count: 20, spacing: 30, hr: 90, motion: 400, into: ctx)
        insertAnchor(day: day(4), restingHR: 99, into: ctx)
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)

        XCTAssertTrue(anchors(on: day(4)).isEmpty,
                      "an anchor the current rules would never produce must not stay in the baseline")
    }

    func testSparseLeadingWindowNoLongerCostsTheDayItsAnchor() async {
        // 06:00: eight samples 70 s apart — a qualifying run whose leading 300 s
        // holds only five, too few to median. 08:00: a dense rest. Before the
        // window check moved into the run filter this deleted the stored anchor
        // and inserted nothing.
        let ctx = ModelContext(container)
        insertRest(day: day(3), hour: 6, count: 8,  spacing: 70, hr: 90, motion: 5, into: ctx)
        insertRest(day: day(3), hour: 8, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        insertAnchor(day: day(3), restingHR: 99, into: ctx)
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)

        let rebuilt = anchors(on: day(3))
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertEqual(rebuilt.first?.restingHR ?? 0, 60, accuracy: 0.001,
                       "the 08:00 rest anchors the day the 06:00 run could not")
    }

    func testTodaysFrozenAnchorIsLeftAlone() async {
        let ctx = ModelContext(container)
        insertRest(day: day(0), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        insertAnchor(day: day(0), restingHR: 99, into: ctx)
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)

        let todays = anchors(on: day(0))
        XCTAssertEqual(todays.count, 1)
        XCTAssertEqual(todays.first?.restingHR ?? 0, 99, accuracy: 0.001,
                       "DailyAnchor is written once, and today's is the row the tick loop may be writing")
    }

    // MARK: - The version flag

    func testAdvancesTheFlagAndThenStopsReplaying() async {
        let ctx = ModelContext(container)
        insertRest(day: day(5), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AnchorBackfill.flagKey), AnchorBackfill.version)
        XCTAssertEqual(anchors().count, 1)

        // Hand-edit the rebuilt anchor; a second call must not touch it.
        let ctx2 = ModelContext(container)
        let stored = try! ctx2.fetch(FetchDescriptor<DailyAnchor>())
        stored.first?.restingHR = 99
        try! ctx2.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)
        XCTAssertEqual(anchors().first?.restingHR ?? 0, 99, accuracy: 0.001)
    }

    func testEmptyStoreCountsAsDone() async {
        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AnchorBackfill.flagKey), AnchorBackfill.version,
                       "nothing to replay is a finished backfill, not a failed one")
    }

    func testSamplesOlderThanTheBaselineWindowAreNotReplayed() async {
        let ctx = ModelContext(container)
        insertRest(day: day(AnchorBaseline.windowDays + 5), hour: 7,
                   count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        insertAnchor(day: day(AnchorBaseline.windowDays + 5), restingHR: 99, into: ctx)
        try! ctx.save()

        await AnchorBackfill.runIfNeeded(container: container, defaults: defaults)

        XCTAssertEqual(anchors(on: day(AnchorBaseline.windowDays + 5)).first?.restingHR ?? 0, 99,
                       accuracy: 0.001,
                       "outside the baseline window a recompute buys nothing, so the row is left as it is")
    }

    // MARK: - When the store fails

    private struct StoreFailure: Error {}

    /// A live store with one operation swapped for a throw. An in-memory
    /// `ModelContainer` has no reachable way to make a real fetch or save fail,
    /// so this is the only way to reach the branches that decide whether the
    /// version flag advances.
    private func failingStore(_ ctx: ModelContext,
                              samples: Bool = false,
                              anchors: Bool = false,
                              save:    Bool = false,
                              onInsert: @escaping (DailyAnchor) -> Void = { _ in })
    -> AnchorBackfill.Store {
        var store = AnchorBackfill.Store.live(ctx)
        if samples { store.samples = { _ in throw StoreFailure() } }
        if anchors { store.anchors = { throw StoreFailure() } }
        if save    { store.save    = { throw StoreFailure() } }
        let insert = store.insert
        store.insert = { insert($0); onInsert($0) }
        return store
    }

    func testAFailedSampleFetchIsNotAnEmptyStore() {
        let ctx = ModelContext(container)
        insertRest(day: day(5), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        try! ctx.save()

        let outcome = AnchorBackfill.replay(failingStore(ctx, samples: true))

        XCTAssertFalse(outcome.saved,
                       "an empty store is done; a store that would not answer is not")
        XCTAssertEqual(outcome.anchorsWritten, 0)
    }

    func testAFailedAnchorFetchWritesNothing() {
        let ctx = ModelContext(container)
        insertRest(day: day(5), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        insertAnchor(day: day(5), restingHR: 99, into: ctx)
        try! ctx.save()

        var inserted = 0
        let outcome = AnchorBackfill.replay(
            failingStore(ctx, anchors: true, onInsert: { _ in inserted += 1 }))

        XCTAssertFalse(outcome.saved)
        XCTAssertEqual(inserted, 0,
                       "an unread anchor list deletes nothing, so inserting would leave two "
                       + "rows for the day — `DailyAnchor` has no unique constraint on `day`")
    }

    func testAFailedSaveDoesNotCountAsSaved() {
        let ctx = ModelContext(container)
        insertRest(day: day(5), hour: 7, count: 20, spacing: 30, hr: 60, motion: 5, into: ctx)
        try! ctx.save()

        let outcome = AnchorBackfill.replay(failingStore(ctx, save: true))

        XCTAssertEqual(outcome.anchorsWritten, 1, "it got as far as building the anchor")
        XCTAssertFalse(outcome.saved, "but nothing reached the store")
    }

    func testTheFlagFollowsSavedAndNothingElse() {
        AnchorBackfill.record(AnchorBackfill.Outcome(daysConsidered: 30, anchorsWritten: 25,
                                                    anchorsDropped: 2, saved: false),
                              in: defaults)
        XCTAssertEqual(defaults.integer(forKey: AnchorBackfill.flagKey), 0,
                       "a replay that did not land must be retried on the next launch")

        AnchorBackfill.record(AnchorBackfill.Outcome(saved: true), in: defaults)
        XCTAssertEqual(defaults.integer(forKey: AnchorBackfill.flagKey), AnchorBackfill.version)
    }
}
