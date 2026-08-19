import XCTest
import SwiftData
@testable import Wythin

/// Guards the "at most one activity is recording" invariant.
///
/// It used to be possible to hold two: the Activities tab hides START NOW while
/// something is running, but the nudge "walk" action called `begin` directly with
/// no such check. The older entry then fell into a gap — the banner showed only
/// the newest active entry and the history list filtered every active entry out —
/// so it had no end time, appeared nowhere, and could not be stopped.
final class ActiveActivityTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func actives(_ ctx: ModelContext) -> [ActivityLog] {
        ((try? ctx.fetch(FetchDescriptor<ActivityLog>())) ?? []).filter(\.isActive)
    }

    // MARK: begin closes what's already running

    func testBeginClosesAnActivityAlreadyRecording() {
        let ctx = makeContext()
        let first = ActivityLogging.begin(type: .work, subtype: "Deep Work", customName: nil,
                                          targetMinutes: nil, context: ctx)
        let second = ActivityLogging.begin(type: .walk, subtype: nil, customName: nil,
                                           targetMinutes: 12, context: ctx)

        XCTAssertNotNil(first.endedAt, "the running activity must be closed, not orphaned")
        XCTAssertFalse(first.isActive)
        XCTAssertTrue(second.isActive)
    }

    func testAtMostOneActivityIsEverRecording() {
        let ctx = makeContext()
        ActivityLogging.begin(type: .work, subtype: nil, customName: nil,
                              targetMinutes: nil, context: ctx)
        ActivityLogging.begin(type: .walk, subtype: nil, customName: nil,
                              targetMinutes: nil, context: ctx)
        ActivityLogging.begin(type: .meditation, subtype: nil, customName: nil,
                              targetMinutes: nil, context: ctx)

        XCTAssertEqual(actives(ctx).count, 1)
    }

    func testTheClosedActivityKeepsItsOwnStartTime() {
        // Closing the previous entry must not rewrite its start — the window it
        // covers is what the HRV averages were computed against.
        let ctx = makeContext()
        let first = ActivityLogging.begin(type: .work, subtype: nil, customName: nil,
                                          targetMinutes: nil, context: ctx)
        let startedAt = first.startedAt
        ActivityLogging.begin(type: .walk, subtype: nil, customName: nil,
                              targetMinutes: nil, context: ctx)

        XCTAssertEqual(first.startedAt, startedAt)
        XCTAssertGreaterThanOrEqual(first.endedAt!, startedAt)
    }

    func testBeginOnAnEmptyLogJustStarts() {
        let ctx = makeContext()
        let entry = ActivityLogging.begin(type: .meditation, subtype: "Vipassana", customName: nil,
                                          targetMinutes: 20, context: ctx)
        XCTAssertTrue(entry.isActive)
        XCTAssertEqual(actives(ctx).count, 1)
    }

    /// A finished entry is not a candidate for closing, and must be left alone.
    func testBeginLeavesFinishedEntriesUntouched() {
        let ctx = makeContext()
        let start = Date().addingTimeInterval(-3600)
        ActivityLogging.logPast(type: .meal, subtype: "Lunch", customName: nil,
                                start: start, end: start.addingTimeInterval(1800),
                                context: ctx, client: NoopClient())
        let past = try! ctx.fetch(FetchDescriptor<ActivityLog>())[0]
        let originalEnd = past.endedAt

        ActivityLogging.begin(type: .walk, subtype: nil, customName: nil,
                              targetMinutes: nil, context: ctx)

        XCTAssertEqual(past.endedAt, originalEnd)
    }

    // MARK: Clearing orphans left by earlier builds

    /// Databases written before the invariant existed can already hold several
    /// unfinished entries. Reaching one has to be possible.
    func testFinishAnyActiveClosesEveryOrphan() {
        let ctx = makeContext()
        for offset in [-7200.0, -3600.0, -600.0] {
            let orphan = ActivityLog(activityType: ActivityType.work.rawValue,
                                     startedAt: Date().addingTimeInterval(offset),
                                     isManual: false)
            ctx.insert(orphan)
        }
        try? ctx.save()
        XCTAssertEqual(actives(ctx).count, 3, "precondition: three orphans")

        ActivityLogging.finishAnyActive(context: ctx, client: nil)

        XCTAssertTrue(actives(ctx).isEmpty)
    }

    // MARK: Surfacing every active entry

    /// The banner drives off this, so it must return *all* of them — showing only
    /// the newest is what hid the orphan in the first place.
    func testActiveEntriesReturnsEveryUnfinishedEntryOldestFirst() {
        let now = Date()
        let older = ActivityLog(activityType: ActivityType.work.rawValue,
                                startedAt: now.addingTimeInterval(-3600), isManual: false)
        let newer = ActivityLog(activityType: ActivityType.walk.rawValue,
                                startedAt: now.addingTimeInterval(-600), isManual: false)
        let done  = ActivityLog(activityType: ActivityType.meal.rawValue,
                                startedAt: now.addingTimeInterval(-7200),
                                endedAt: now.addingTimeInterval(-7000), isManual: true)

        let result = ActivityLogging.activeEntries(in: [newer, done, older])

        XCTAssertEqual(result.count, 2, "the finished entry is not active")
        XCTAssertEqual(result.first?.activityType, ActivityType.work.rawValue,
                       "oldest first, so a stale orphan surfaces at the top")
        XCTAssertEqual(result.last?.activityType, ActivityType.walk.rawValue)
    }

    func testActiveEntriesIsEmptyWhenNothingIsRecording() {
        let now = Date()
        let done = ActivityLog(activityType: ActivityType.meal.rawValue,
                               startedAt: now.addingTimeInterval(-600),
                               endedAt: now, isManual: true)
        XCTAssertTrue(ActivityLogging.activeEntries(in: [done]).isEmpty)
    }

    // MARK: The after-window
    //
    // The after-window is ten minutes that begin when a session ends, so at the
    // moment the session is stored none of it has happened. Every after field is
    // necessarily nil at that point, and something has to come back for it. The
    // old guard only ever re-ran an entry whose *during* window was missing, so
    // a session with a good during and an empty after was never revisited — the
    // AFT column read "—" for the life of the entry.

    private func finished(_ ago: TimeInterval, during: Float?, after: Float?) -> ActivityLog {
        let e = ActivityLog(activityType: ActivityType.breathwork.rawValue,
                            startedAt: Date().addingTimeInterval(-ago - 600),
                            endedAt: Date().addingTimeInterval(-ago),
                            isManual: false)
        e.duringStress = during
        e.afterStress  = after
        return e
    }

    func testAnEntryWithNoAfterWindowIsRefreshedOnceTheWindowHasClosed() {
        let e = finished(20 * 60, during: 44, after: nil)
        XCTAssertTrue(e.needsWindowRefresh(), "twenty minutes on, the after-window exists to be read")
    }

    /// Filling it early would store a partial window — and because the guard
    /// then sees a value, it would never be corrected.
    func testAnEntryIsNotRefreshedWhileItsAfterWindowIsStillFilling() {
        XCTAssertFalse(finished(3 * 60, during: 44, after: nil).needsWindowRefresh(),
                       "only three minutes of a ten-minute window have happened")
    }

    func testAnEntryThatAlreadyHasAnAfterWindowIsLeftAlone() {
        XCTAssertFalse(finished(60 * 60, during: 44, after: 41).needsWindowRefresh())
    }

    func testAnEntryMissingItsDuringWindowIsAlwaysRefreshed() {
        XCTAssertTrue(finished(30, during: nil, after: nil).needsWindowRefresh(),
                      "a missing during window is worth recomputing whenever we notice")
    }

    /// Past the cutoff an empty after-window means the strap was off, and
    /// relaunching will not conjure samples that were never recorded.
    func testAStaleEmptyAfterWindowStopsBeingRetried() {
        XCTAssertFalse(finished(5 * 24 * 3600, during: 44, after: nil).needsWindowRefresh())
    }

    func testAnActivityStillRecordingIsNeverRefreshed() {
        let live = ActivityLog(activityType: ActivityType.breathwork.rawValue, isManual: false)
        XCTAssertNil(live.endedAt)
        XCTAssertFalse(live.needsWindowRefresh())
    }
}

private struct NoopClient: InsightAPIClient {
    struct Stop: Error {}
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse { throw Stop() }
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse { throw Stop() }
}
