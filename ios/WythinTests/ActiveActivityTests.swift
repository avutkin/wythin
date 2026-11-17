import XCTest
import SwiftData
import SwiftUI
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
        XCTAssertNil(past.timezone, "a retrospective entry has no evidence of the historical phone zone")
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

    func testFinishingAgainDoesNotMoveTheSavedEndTime() {
        let ctx = makeContext()
        let finishedAt = Date(timeIntervalSince1970: 1_000_600)
        let entry = ActivityLog(activityType: ActivityType.exercise.rawValue,
                                startedAt: finishedAt.addingTimeInterval(-600),
                                endedAt: finishedAt, isManual: false)
        ctx.insert(entry)
        try? ctx.save()
        ActivityLogging.end(entry, context: ctx, client: nil)
        XCTAssertEqual(entry.endedAt, finishedAt, "Finish must be idempotent")
    }

    func testLiveSessionSurvivesReloadWithoutAcquiringAnEndTime() throws {
        let ctx = makeContext()
        let entry = ActivityLogging.begin(type: .exercise, subtype: "Easy Run", customName: nil,
                                          targetMinutes: nil, context: ctx)
        let reloaded = try XCTUnwrap(ModelContext(ctx.container).fetch(FetchDescriptor<ActivityLog>()).first)
        XCTAssertEqual(reloaded.id, entry.id)
        XCTAssertEqual(reloaded.startedAt, entry.startedAt)
        XCTAssertNil(reloaded.endedAt)
        XCTAssertNil(reloaded.targetMinutes)
        XCTAssertTrue(reloaded.isActive)
        XCTAssertEqual(LiveActivityPresentation.clock(startedAt: reloaded.startedAt,
            now: entry.startedAt.addingTimeInterval(3_725)), "01:02:05")
    }

    func testLiveEntriesStayOutOfHistoryUntilFinish() throws {
        let ctx = makeContext()
        let past = ActivityLog(activityType: "Walk", startedAt: .now.addingTimeInterval(-300),
                               endedAt: .now.addingTimeInterval(-60), isManual: true)
        let active = ActivityLogging.begin(type: .exercise, subtype: "Easy Run", customName: nil,
                                           targetMinutes: nil, context: ctx)
        ctx.insert(past)
        XCTAssertEqual(ActivityLogging.historyEntries(in: [active, past]).map(\.id), [past.id])
        XCTAssertEqual(ActivityLogging.activeEntries(in: [active, past]).map(\.id), [active.id])
        let began = active.startedAt
        ActivityLogging.end(active, context: ctx, client: nil)
        XCTAssertEqual(active.startedAt, began)
        XCTAssertNotNil(active.endedAt)
        XCTAssertTrue(ActivityLogging.activeEntries(in: [active, past]).isEmpty)
        XCTAssertEqual(ActivityLogging.historyEntries(in: [active, past]).map(\.id), [active.id, past.id])
        let saved = try ModelContext(ctx.container).fetch(FetchDescriptor<ActivityLog>())
        XCTAssertNotNil(saved.first(where: { $0.id == active.id })?.endedAt)
    }

    func testElapsedClockAdvancesWithoutMetricsAndDoesNotFinishAtTarget() {
        let began = Date(timeIntervalSince1970: 1_000_000)
        let entry = ActivityLog(activityType: "Exercise", startedAt: began, targetMinutes: 5)
        XCTAssertEqual(LiveActivityPresentation.clock(startedAt: began, now: began), "00:00")
        XCTAssertEqual(LiveActivityPresentation.clock(startedAt: began, now: began.addingTimeInterval(1)), "00:01")
        XCTAssertEqual(LiveActivityPresentation.clock(startedAt: began, now: began.addingTimeInterval(601)), "10:01")
        XCTAssertTrue(entry.isActive)
        XCTAssertNil(entry.endedAt)
        XCTAssertEqual(LiveActivityPresentation.clock(startedAt: began, now: began.addingTimeInterval(-10)), "00:00")
    }

    func testLiveReadingsRequireFreshMeasurementsFromThisSession() {
        let began = Date(timeIntervalSince1970: 1_000_000)
        let now = began.addingTimeInterval(30)
        let point = MetricsHistoryPoint(timestamp: now, meanBPM: 166, rmssd: 18, sdnn: 22)
        XCTAssertEqual(LiveActivityPresentation.currentPoint(point, startedAt: began,
            now: now, signalAvailable: true)?.meanBPM, 166)
        XCTAssertNil(LiveActivityPresentation.currentPoint(point, startedAt: began,
            now: now.addingTimeInterval(7), signalAvailable: true), "A stopped stream is not live")
        XCTAssertNil(LiveActivityPresentation.currentPoint(point, startedAt: began,
            now: now, signalAvailable: false))
        XCTAssertNil(LiveActivityPresentation.currentPoint(point, startedAt: now.addingTimeInterval(1),
            now: now.addingTimeInterval(1), signalAvailable: true), "Do not borrow the previous session's reading")
        XCTAssertNil(LiveActivityPresentation.currentPoint(point, startedAt: began,
            now: now.addingTimeInterval(-1), signalAvailable: true))
        XCTAssertNil(LiveActivityPresentation.currentPoint(nil, startedAt: began,
            now: now, signalAvailable: true))
    }

    func testLiveReadingsUseCurrentValuesAndLeaveMissingValuesBlank() {
        let now = Date()
        var point = MetricsHistoryPoint(timestamp: now, meanBPM: 166, rmssd: 18, dc: 3)
        point.stressBalance = 62
        XCTAssertEqual(LiveActivityPresentation.value(.hr, point: point), 166)
        XCTAssertEqual(LiveActivityPresentation.value(.stressBalance, point: point), 62)
        XCTAssertNil(LiveActivityPresentation.value(.breathBPM, point: point))
        XCTAssertNil(LiveActivityPresentation.value(.hr, point: nil))
        let invalid = MetricsHistoryPoint(timestamp: now, meanBPM: .nan)
        XCTAssertNil(LiveActivityPresentation.value(.hr, point: invalid))
    }

    /// Static render of the production view for visual review; no UI automation
    /// or synthetic measurements enter the app's persistent store.
    @MainActor
    func testLiveActivityCardRendersAtCompactPhoneWidth() throws {
        let began = Date(timeIntervalSince1970: 1_000_000)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Easy Run", startedAt: began)
        let now = began.addingTimeInterval(793)
        let point = MetricsHistoryPoint(timestamp: now, meanBPM: 166, rmssd: 18.4,
                                        breathBPM: 25, dc: 3.2)
        for (name, reading) in [("live", Optional(point)), ("waiting", nil)] {
            let view = LiveActivityCard(entry: entry, now: now, point: reading, onFinish: {})
                .padding(16).frame(width: 375).background(Theme.bg)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "activity-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("activity-\(name)-preview.png")
            try XCTUnwrap(image.pngData()).write(to: url)
        }
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
        // "Has an after window" now means it was computed with the window
        // complete — the settled marker — not merely that a value is present.
        // The live row fills the after fields early, every tick, so presence
        // alone would leave a two-minute partial window standing as the result.
        let e = finished(60 * 60, during: 44, after: 41)
        e.settledAt = Date()
        XCTAssertFalse(e.needsWindowRefresh())
    }

    func testAPartialAfterWindowIsRefreshedOnceComplete() {
        // Computed early (settledAt nil) and the ten minutes have passed: read
        // it again, whatever the early read stored.
        XCTAssertTrue(finished(60 * 60, during: 44, after: 41).needsWindowRefresh())
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

    // MARK: - The running toast's heart-rate trace

    func testTraceKeepsOnlyTheWindowAndNormalisesToTheUnitSquare() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let samples: [(Date, Float?)] = [
            (now.addingTimeInterval(-200), 60),      // outside the window
            (now.addingTimeInterval(-60), 100),
            (now.addingTimeInterval(-30), 140),
            (now.addingTimeInterval(-10), nil),      // a tick with no heart rate
            (now, 120),
        ]
        let pts = HeartRateTrace.normalised(samples: samples, window: 90, now: now)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts.first!.x, 1 - 60.0 / 90, accuracy: 0.001)
        XCTAssertEqual(pts.last!.x, 1, accuracy: 0.001)
        XCTAssertEqual(pts.map(\.y), [0, 1, 0.5].map { CGFloat($0) })
    }

    func testTraceNeedsTwoPointsAndSurvivesAFlatLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(HeartRateTrace.normalised(samples: [(now, 90)], window: 90, now: now).isEmpty)
        let flat = HeartRateTrace.normalised(samples: [(now.addingTimeInterval(-10), 90), (now, 90)],
                                             window: 90, now: now)
        XCTAssertEqual(flat.map(\.y), [0.5, 0.5], "a flat trace sits mid-height, not at the floor")
    }
}

private struct NoopClient: InsightAPIClient {
    struct Stop: Error {}
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse { throw Stop() }
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse { throw Stop() }
    func generateSleepInsight(_ payload: SleepInsightPayload) async throws -> InsightResponse { throw Stop() }
}
