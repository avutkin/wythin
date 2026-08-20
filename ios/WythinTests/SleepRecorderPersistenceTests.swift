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
        let schema = Schema([ActivityLog.self, HRVSample.self, HRVSession.self, DailyAnchor.self])
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
