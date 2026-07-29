import XCTest
@testable import Wythin

final class ConsistencySummaryTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.startOfDay(for: date(y, m, d))
    }

    private func rollup(_ d: Date, wearSeconds: Double) -> DailyRollup {
        DailyRollup(day: d, dc: 8, rmssd: nil, rsaMs: nil, rcmse: nil, pip: nil,
                    dfa1: nil, stressBalance: nil, vti: nil, meanBPM: nil,
                    sampleCount: 200, wearSeconds: wearSeconds)
    }

    private var week: TrackRange {
        TrackRangeBuilder.range(period: .week, offset: 0,
                                today: date(2026, 7, 28), calendar: cal)   // Mon 27 Jul – Sun 2 Aug
    }

    func testPracticeMinutesLandOnTheStartDay() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 27, 9),
                                 endedAt:   date(2026, 7, 27, 9).addingTimeInterval(20 * 60))]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].practiceMinutes, 20, accuracy: 0.001)
        XCTAssertEqual(s.buckets[1].practiceMinutes, 0, accuracy: 0.001)
        XCTAssertEqual(s.totalPracticeMinutes, 20, accuracy: 0.001)
        XCTAssertEqual(s.sessionCount, 1)
    }

    func testMultipleSessionsOnADayAccumulate() {
        let acts = [
            ActivitySpan(startedAt: date(2026, 7, 27, 9),
                         endedAt: date(2026, 7, 27, 9).addingTimeInterval(10 * 60)),
            ActivitySpan(startedAt: date(2026, 7, 27, 18),
                         endedAt: date(2026, 7, 27, 18).addingTimeInterval(15 * 60)),
        ]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].practiceMinutes, 25, accuracy: 0.001)
        XCTAssertEqual(s.sessionCount, 2)
    }

    func testActivitySpanningMidnightIsAttributedToItsStartDay() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 27, 23),
                                 endedAt:   date(2026, 7, 28, 0).addingTimeInterval(30 * 60))]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].practiceMinutes, 90, accuracy: 0.001)
        XCTAssertEqual(s.buckets[1].practiceMinutes, 0, accuracy: 0.001)
    }

    func testUnfinishedActivitiesAreIgnored() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 27, 9), endedAt: nil)]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.sessionCount, 0)
        XCTAssertEqual(s.totalPracticeMinutes, 0, accuracy: 0.001)
    }

    func testActivitiesOutsideTheRangeAreExcluded() {
        let acts = [ActivitySpan(startedAt: date(2026, 7, 20, 9),
                                 endedAt: date(2026, 7, 20, 10))]
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.sessionCount, 0)
    }

    func testWearHoursComeFromRollups() {
        let rollups = [rollup(day(2026, 7, 27), wearSeconds: 3600 * 16),
                       rollup(day(2026, 7, 28), wearSeconds: 3600 * 8)]
        let s = ConsistencyBuilder.build(range: week, activities: [], rollups: rollups,
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets[0].wearHours, 16, accuracy: 0.001)
        XCTAssertEqual(s.buckets[1].wearHours, 8, accuracy: 0.001)
        XCTAssertEqual(s.buckets[2].wearHours, 0, accuracy: 0.001)
    }

    func testAverageWearIgnoresDaysWithNoData() {
        let rollups = [rollup(day(2026, 7, 27), wearSeconds: 3600 * 16),
                       rollup(day(2026, 7, 28), wearSeconds: 3600 * 8)]
        let s = ConsistencyBuilder.build(range: week, activities: [], rollups: rollups,
                                         today: day(2026, 7, 28), calendar: cal)
        // 12, not 24/7 — days the strap was off are absent, not zero.
        XCTAssertEqual(s.avgWearHours, 12, accuracy: 0.001)
    }

    func testStreakCountsConsecutivePracticeDays() {
        // Practice on today and the three days before it.
        let acts = (0...3).map { back -> ActivitySpan in
            let d = cal.date(byAdding: .day, value: -back, to: date(2026, 7, 28, 9))!
            return ActivitySpan(startedAt: d, endedAt: d.addingTimeInterval(600))
        }
        let s = ConsistencyBuilder.build(range: week, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.streak.current, 4)
    }

    func testEmptyRangeProducesZeroes() {
        let s = ConsistencyBuilder.build(range: week, activities: [], rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.buckets.count, 7)
        XCTAssertEqual(s.sessionCount, 0)
        XCTAssertEqual(s.avgWearHours, 0, accuracy: 0.001)
        XCTAssertEqual(s.streak.current, 0)
    }
}
