import SwiftData
import XCTest
@testable import Wythin

/// The recorder runs on a background `ModelContext` now, and a hand-made
/// context does NOT autosave the way `container.mainContext` does. Everything
/// it does — inserts *and* deletes — has to be explicitly committed, or the
/// work is silently discarded when the context goes out of scope.
final class SleepRecorderPersistenceTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let schema = Schema([ActivityLog.self, HRVSample.self, HRVSession.self, DailyAnchor.self, SleepWindowOverride.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    /// A night's worth of samples, 23:10 → 06:40.
    private func seedNight(_ context: ModelContext, day: Int) {
        var comps = DateComponents(year: 2026, month: 7, day: day)
        comps.hour = 23; comps.minute = 10
        let start = Calendar.current.date(from: comps)!
        for i in 0..<Int(7.5 * 120) {
            let s = HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                              meanBPM: 52, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                              breathBPM: 13, motion: 6,
                              signalQuality: 0.97, rrInvalidRate: 0.01)
            context.insert(s)
        }
        try! context.save()
    }

    private func at(_ day: Int, _ hour: Int) -> Date {
        var c = DateComponents(year: 2026, month: 7, day: day)
        c.hour = hour
        return Calendar.current.date(from: c)!
    }

    private func sleepLogs(in context: ModelContext) -> [ActivityLog] {
        let all = (try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []
        return all.filter { $0.activityType == ActivityType.sleep.rawValue }
    }

    // MARK: - The sleeper's own correction

    func testACorrectionMovesTheRecordedNight() {
        // The detector proposes; the sleeper corrects. A chest strap cannot see
        // you close your eyes, so the boundary is genuinely ambiguous for the
        // one person who can settle it.
        let writer = ModelContext(container)
        seedNight(writer, day: 20)
        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))
        guard let before = sleepLogs(in: writer).first else { return XCTFail("no night") }
        let day = Calendar.current.startOfDay(for: before.endedAt!)

        // "I was actually awake from seven."
        let corrected = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0,
                                              of: before.endedAt!)!
        writer.insert(SleepWindowOverride(day: day, endedAt: corrected))
        try! writer.save()
        SleepRecorder.recordIfDue(context: writer, now: at(21, 9))

        let after = sleepLogs(in: ModelContext(container))
        XCTAssertEqual(after.count, 1, "correcting a night must not create a second one")
        XCTAssertEqual(after.first?.endedAt?.timeIntervalSince(corrected) ?? .infinity, 0,
                       accuracy: 60, "the night should end where the sleeper said")
    }

    func testACorrectionSurvivesAnAlgorithmBump() {
        // The reason the correction is stored beside the night rather than on
        // it. Every algorithm bump purges stored nights and re-detects them; a
        // correction living on the night would be deleted with it, and the
        // sleeper would have to make the same drag again after every release.
        let writer = ModelContext(container)
        seedNight(writer, day: 20)
        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))
        guard let before = sleepLogs(in: writer).first, let end = before.endedAt else {
            return XCTFail("no night")
        }
        let day = Calendar.current.startOfDay(for: end)
        let corrected = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: end)!
        writer.insert(SleepWindowOverride(day: day, endedAt: corrected))
        try! writer.save()
        SleepRecorder.recordIfDue(context: writer, now: at(21, 9))

        // Simulate the bump: the stored night is from an older pipeline.
        for log in sleepLogs(in: writer) { log.sleepAlgorithmVersion = 0 }
        try! writer.save()
        SleepRecorder.recordIfDue(context: writer, now: at(21, 10))

        let after = sleepLogs(in: ModelContext(container))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.endedAt?.timeIntervalSince(corrected) ?? .infinity, 0,
                       accuracy: 60, "the correction must outlive the night it corrected")
    }

    func testAnUncorrectedNightIsNotRewrittenEveryPass() {
        // The guard on the rebuild rule. Comparing stored dates for exact
        // equality would find a disagreement every pass and delete-and-rewrite
        // the night forever.
        let writer = ModelContext(container)
        seedNight(writer, day: 20)
        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))
        guard let first = sleepLogs(in: writer).first, let end = first.endedAt else {
            return XCTFail("no night")
        }
        let day = Calendar.current.startOfDay(for: end)
        // A correction that agrees with what was detected.
        writer.insert(SleepWindowOverride(day: day, endedAt: end))
        try! writer.save()
        SleepRecorder.recordIfDue(context: writer, now: at(21, 9))

        let after = sleepLogs(in: ModelContext(container))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.endedAt?.timeIntervalSince(end) ?? .infinity, 0, accuracy: 1)
    }

    func testACorrectionCannotInvertTheNight() {
        // A handle dragged past its opposite number. The window is divided by
        // everywhere downstream — durations, stage shares, efficiency, the
        // score — so an inverted one does not fail loudly, it quietly poisons
        // every number derived from it.
        let start = at(20, 23)
        let end = Calendar.current.date(byAdding: .hour, value: 7, to: start)!
        let night = SleepWindow(startedAt: start, endedAt: end)

        let backwards = SleepWindowOverride(day: Calendar.current.startOfDay(for: end),
                                            startedAt: end.addingTimeInterval(3600))
        XCTAssertEqual(backwards.applied(to: night), night,
                       "an inverted correction is refused, not stored")

        let sane = SleepWindowOverride(day: Calendar.current.startOfDay(for: end),
                                       endedAt: end.addingTimeInterval(-3600))
        XCTAssertEqual(sane.applied(to: night).endedAt, end.addingTimeInterval(-3600))
        XCTAssertEqual(sane.applied(to: night).startedAt, start,
                       "an untouched edge keeps whatever the detector found")
    }

    // MARK: - Naps

    private func napLogs(in context: ModelContext) -> [ActivityLog] {
        let all = (try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []
        return all.filter { $0.activityType == ActivityType.nap.rawValue }
    }

    func testDetectedNapsAreRemovedAndLoggedOnesAreNot() {
        // Automatic nap detection shipped and was withdrawn. Deleting the
        // detector is not enough on its own: what it already wrote stays in the
        // store, and nothing else would ever revisit it, so a withdrawn
        // feature's leftovers would sit on the timeline looking exactly like
        // something the app still believes.
        //
        // The user's own entries are a different matter entirely, and survive.
        let writer = ModelContext(container)
        seedNight(writer, day: 20)

        let detected = ActivityLog(activityType: ActivityType.nap.rawValue,
                                   startedAt: at(20, 14))
        detected.endedAt = Calendar.current.date(byAdding: .minute, value: 30, to: at(20, 14))
        detected.isManual = false
        let logged = ActivityLog(activityType: ActivityType.nap.rawValue,
                                 startedAt: at(20, 16))
        logged.endedAt = Calendar.current.date(byAdding: .minute, value: 30, to: at(20, 16))
        logged.isManual = true
        writer.insert(detected)
        writer.insert(logged)
        try! writer.save()

        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))

        let naps = napLogs(in: ModelContext(container))
        XCTAssertEqual(naps.count, 1, "the detected nap should be gone")
        XCTAssertEqual(naps.first?.isManual, true,
                       "and the one the user logged themselves should not be")
    }


    func testARecordedNightSurvivesTheBackgroundContext() {
        let writer = ModelContext(container)
        seedNight(writer, day: 20)
        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))

        // A DIFFERENT context — proof it reached the store, not just the
        // in-memory graph of the context that wrote it.
        let reader = ModelContext(container)
        XCTAssertEqual(sleepLogs(in: reader).count, 1,
                       "the night was never committed to the store")
    }

    func testDeletingAStaleVersionNightIsCommittedEvenWhenNothingIsRewritten() {
        // The algorithm-version bump path: an old night is deleted so it can be
        // rebuilt. If no replacement happens to be written in the same pass —
        // no samples for it, or it falls outside the lookback — the deletion
        // still has to persist. Otherwise the user keeps seeing numbers from an
        // algorithm that no longer exists, which is exactly the symptom the
        // version field exists to prevent.
        let writer = ModelContext(container)
        let stale = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: at(20, 23))
        stale.endedAt = at(21, 6)
        stale.sleepAlgorithmVersion = SleepThresholds.algorithmVersion - 1
        writer.insert(stale)
        try! writer.save()

        // No HRVSamples seeded, so nothing can be re-recorded this pass.
        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))

        let reader = ModelContext(container)
        XCTAssertTrue(sleepLogs(in: reader).isEmpty,
                      "the stale night is still in the store — the delete was discarded")
    }

    /// The exact upgrade path the phone is on: nights on disk from the old
    /// share-based pipeline, samples still present, new algorithm version.
    ///
    /// This is what "I don't see changes in the app" looks like from the
    /// store's side — if the old row survives, the user keeps reading numbers
    /// from an algorithm that was deleted.
    func testAnOldVersionNightIsReplacedByOneFromTheCurrentPipeline() {
        let writer = ModelContext(container)
        seedNight(writer, day: 20)

        // A night already on disk, written by the previous algorithm, covering
        // the same window the samples describe.
        let stale = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: at(20, 23))
        stale.endedAt = at(21, 6)
        stale.sleepAlgorithmVersion = SleepThresholds.algorithmVersion - 1
        stale.sleepAsleepMinutes = 999          // an obviously stale marker
        writer.insert(stale)
        try! writer.save()

        SleepRecorder.recordIfDue(context: writer, now: at(21, 8))

        let reader = ModelContext(container)
        let logs = sleepLogs(in: reader)
        XCTAssertEqual(logs.count, 1, "one night in, one night out")
        XCTAssertEqual(logs.first?.sleepAlgorithmVersion, SleepThresholds.algorithmVersion,
                       "the surviving night is still on the old algorithm")
        XCTAssertNotEqual(logs.first?.sleepAsleepMinutes, 999,
                          "this is the stale row, not a rebuilt one")
    }
}
