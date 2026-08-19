import XCTest
import SwiftData
@testable import Wythin

/// The step that turns a detected night into something the user can actually
/// see. Everything before this was pure computation nothing ever called.
final class SleepRecorderTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let schema = Schema([HRVSample.self, HRVSession.self, DailyAnchor.self, ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() { container = nil; super.tearDown() }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents(year: 2026, month: 7, day: day)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    /// Inserts a night of samples: 23:10 on the 20th → 06:40 on the 21st,
    /// with a heart rate that dips and recovers the way a real night does.
    private func insertNight(into ctx: ModelContext) {
        let start = at(20, 23, 10)
        let count = Int(7.5 * 3600 / 30)
        for i in 0..<count {
            let f = Double(i) / Double(count)
            let bowl = exp(-pow(f - 0.45, 2) / (2 * 0.11))
            ctx.insert(HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                 meanBPM: Float(62 - 14 * bowl),
                                 vti: 3.9, rmssd: 49, sdnn: 58, dc: 8, pip: 45, dfa1: 1.0,
                                 breathBPM: 13, motion: 6,
                                 signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2))
        }
    }

    private func sleepLogs(_ ctx: ModelContext) -> [ActivityLog] {
        (try? ctx.fetch(FetchDescriptor<ActivityLog>()))?
            .filter { $0.activityType == ActivityType.sleep.rawValue } ?? []
    }

    // MARK: - Tests

    func testRecordsLastNightAsAnActivity() {
        let ctx = ModelContext(container)
        insertNight(into: ctx)

        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))

        let logs = sleepLogs(ctx)
        XCTAssertEqual(logs.count, 1, "the night should appear in Activities")
        guard let night = logs.first else { return }
        XCTAssertEqual(night.startedAt, at(20, 23, 10))
        XCTAssertNotNil(night.endedAt)
        XCTAssertEqual(night.endedAt?.timeIntervalSince(night.startedAt) ?? 0,
                       7.5 * 3600, accuracy: 120)
        XCTAssertTrue(night.isManual == false, "this was measured, not entered")
    }

    func testDoesNotRecordTheSameNightTwice() {
        let ctx = ModelContext(container)
        insertNight(into: ctx)

        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8, 30))
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 12))

        XCTAssertEqual(sleepLogs(ctx).count, 1, "the poll runs all day and must write once")
    }

    func testDoesNotRecordANightStillInProgress() {
        let ctx = ModelContext(container)
        insertNight(into: ctx)

        SleepRecorder.recordIfDue(context: ctx, now: at(21, 3))

        XCTAssertTrue(sleepLogs(ctx).isEmpty, "still asleep — nothing to write yet")
    }

    func testCarriesTheNightsMetrics() {
        let ctx = ModelContext(container)
        insertNight(into: ctx)
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))

        guard let night = sleepLogs(ctx).first else { return XCTFail("no night recorded") }
        XCTAssertNotNil(night.duringHR, "window averages must be computed like any activity")
        XCTAssertNotNil(night.sleepScore, "a night without a score is not worth showing")
        XCTAssertNotNil(night.sleepStageSummary)
    }

    func testSleepIsARestorativeClass() {
        // It must not land on the exercise path, which would give it a TRIMP
        // load, a suppression axis and workout-shaped expectations.
        XCTAssertEqual(ActivityType.sleep.activityClass, .restorative)
    }

    // MARK: - How a night presents in Activities

    func testNightNeverGetsTheExerciseSections() {
        // Left on the default path a night inherits Mobilized, Cost and
        // Recovery — how fast you rose to the load, the vagal cost of that
        // rise, and heart-rate recovery after stopping. Every one of those is
        // a workout construct applied to eight hours of lying still.
        let ctx = ModelContext(container)
        insertNight(into: ctx)
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))
        guard let night = sleepLogs(ctx).first else { return XCTFail("no night") }

        let names = night.indexSlots.map(\.name)
        for workoutSection in ["Mobilised", "Mobilized", "Cost", "Recovery"] {
            XCTAssertFalse(names.contains(workoutSection),
                           "\(workoutSection) is a workout section: \(names)")
        }
    }

    func testNightPresentsItsOwnFiveSections() {
        let ctx = ModelContext(container)
        insertNight(into: ctx)
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))
        guard let night = sleepLogs(ctx).first else { return XCTFail("no night") }

        let names = night.indexSlots.map(\.name)
        XCTAssertEqual(names, ["Timing", "Duration", "Continuity", "Autonomic", "Breathing"])
    }

    func testBreathingIsMeasuredWhenBreathRateExists() {
        // This section used to report "not measured" on the grounds that
        // steadiness needs a respiratory-effort waveform. Breath rate has 97%
        // coverage on a real night, and its variability is the single best
        // wake/sleep discriminator in that recording — the signal was there
        // all along, only the derivation was missing.
        let ctx = ModelContext(container)
        insertNight(into: ctx)
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))
        guard let night = sleepLogs(ctx).first else { return XCTFail("no night") }

        XCTAssertNotNil(night.sleepBreathing, "breath rate was recorded, so steadiness is derivable")
    }

    func testASectionWithNoInputStaysAbsentRatherThanZero() {
        // The principle the previous test was protecting, on a case where the
        // input genuinely is missing. Zero would read as "your breathing was
        // terrible"; absent reads as "we did not measure it".
        let ctx = ModelContext(container)
        let start = at(20, 23, 10)
        for i in 0..<Int(7.5 * 3600 / 30) {
            let f = Double(i) / (7.5 * 120)
            let bowl = exp(-pow(f - 0.45, 2) / (2 * 0.11))
            ctx.insert(HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                 meanBPM: Float(62 - 14 * bowl),
                                 vti: 3.9, rmssd: 49, sdnn: 58, dc: 8, pip: 45, dfa1: 1.0,
                                 breathBPM: nil, motion: 6,
                                 signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2))
        }
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))
        guard let night = sleepLogs(ctx).first else { return XCTFail("no night") }

        XCTAssertNil(night.sleepBreathing)
        XCTAssertNil(night.indexSlots.first { $0.name == "Breathing" }?.index)
    }

    func testNightDoesNotGetARestorativePracticeScore() {
        // during-vs-before uplift: sleeping HRV against the five minutes before
        // sleep onset is a huge apparent "benefit" and would score near 100.
        let ctx = ModelContext(container)
        insertNight(into: ctx)
        SleepRecorder.recordIfDue(context: ctx, now: at(21, 8))
        guard let night = sleepLogs(ctx).first else { return XCTFail("no night") }

        XCTAssertFalse(night.showsRestorativeScore,
                       "a night is not a practice with a before-window")
    }
}
