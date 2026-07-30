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

    // MARK: streak is period-scoped

    /// Paging back to an earlier page must report the streak as it stood on
    /// that page, not today's streak. A 3-day streak ending on the March
    /// week's last day, with no practice anywhere near the real "today"
    /// (July 28) that gets passed in as the caller's clock.
    func testStreakOnAnEarlierPageReflectsThatPageNotToday() {
        let marchWeek = TrackRangeBuilder.range(period: .week, offset: 0,
                                                today: date(2026, 3, 18), calendar: cal)
        let lastDay = cal.date(byAdding: .day, value: -1, to: marchWeek.end)!
        let acts = (0..<3).map { back -> ActivitySpan in
            let d = cal.date(byAdding: .day, value: -back, to: lastDay)!
            return ActivitySpan(startedAt: d.addingTimeInterval(9 * 3600),
                                endedAt:   d.addingTimeInterval(9 * 3600 + 600))
        }
        let s = ConsistencyBuilder.build(range: marchWeek, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.streak.current, 3)
    }

    /// A streak that starts before the page's first bucket and runs through
    /// to the page's last day must still count in full — `practiceDays` is
    /// populated for every finished activity regardless of range, precisely
    /// so a run bleeding in from before the page still shows up here. Nine
    /// consecutive days against a 7-day page proves the extra two came from
    /// outside the page.
    func testStreakBleedingInFromBeforeThePageStillCountsInFull() {
        let marchWeek = TrackRangeBuilder.range(period: .week, offset: 0,
                                                today: date(2026, 3, 18), calendar: cal)
        let lastDay = cal.date(byAdding: .day, value: -1, to: marchWeek.end)!
        let acts = (0..<9).map { back -> ActivitySpan in
            let d = cal.date(byAdding: .day, value: -back, to: lastDay)!
            return ActivitySpan(startedAt: d.addingTimeInterval(9 * 3600),
                                endedAt:   d.addingTimeInterval(9 * 3600 + 600))
        }
        let s = ConsistencyBuilder.build(range: marchWeek, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.streak.current, 9)
    }

    /// The streak must not bleed into the *following* page. Practice on the
    /// page's last three days (Mar 20-22, the tail of the Mar 16-22 week)
    /// plus the first day of the next page (Mar 23) would report a 4-day
    /// streak if the anchor were evaluated at `range.end` instead of
    /// `range.end - 1 day` — `range.end` is exclusive, so it names the next
    /// page's first day, not this page's last. The correct answer is 3: Mar
    /// 23's practice belongs to the next page's streak, not this one's.
    func testStreakDoesNotBleedIntoTheFollowingPage() {
        let marchWeek = TrackRangeBuilder.range(period: .week, offset: 0,
                                                today: date(2026, 3, 18), calendar: cal)
        let lastDayOfPage = cal.date(byAdding: .day, value: -1, to: marchWeek.end)!  // Mar 22
        let firstDayOfNextPage = marchWeek.end                                       // Mar 23
        let practiceDays = [
            cal.date(byAdding: .day, value: -2, to: lastDayOfPage)!,  // Mar 20
            cal.date(byAdding: .day, value: -1, to: lastDayOfPage)!,  // Mar 21
            lastDayOfPage,                                            // Mar 22
            firstDayOfNextPage,                                       // Mar 23
        ]
        let acts = practiceDays.map { d -> ActivitySpan in
            ActivitySpan(startedAt: d.addingTimeInterval(9 * 3600),
                        endedAt:   d.addingTimeInterval(9 * 3600 + 600))
        }
        let s = ConsistencyBuilder.build(range: marchWeek, activities: acts, rollups: [],
                                         today: day(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.streak.current, 3)
    }

    // MARK: multi-day buckets (6M)

    private var sixMonth: TrackRange {
        TrackRangeBuilder.range(period: .sixMonth, offset: 0,
                                today: date(2026, 7, 28), calendar: cal)   // FEB – JUL 2026
    }

    /// A 6M bucket is a whole calendar month, so the aggregation rule that is
    /// invisible in W and M (one day per bucket) is the whole story here.
    ///
    /// Wear must be the **mean** daily hours, not the month's total: the row
    /// is captioned `avg h/day` and labels every bar in 6M, so summing printed
    /// "434" over a caption reading "avg 14.2 h/day" — a number the user can
    /// only read as a wear collapse. Practice minutes stay a total, matching
    /// the row's own "72 min" stat.
    func testSixMonthBucketAveragesWearAndSumsPractice() {
        let june = [rollup(day(2026, 6, 1), wearSeconds: 3600 * 12),
                    rollup(day(2026, 6, 2), wearSeconds: 3600 * 18),
                    rollup(day(2026, 6, 3), wearSeconds: 3600 * 6)]
        let acts = (1...3).map { d -> ActivitySpan in
            let s = date(2026, 6, d, 9)
            return ActivitySpan(startedAt: s, endedAt: s.addingTimeInterval(20 * 60))
        }
        let s = ConsistencyBuilder.build(range: sixMonth, activities: acts, rollups: june,
                                         today: day(2026, 7, 28), calendar: cal)

        XCTAssertEqual(s.buckets.count, 6)
        let juneBucket = s.buckets.first { $0.bucket.start == day(2026, 6, 1) }!
        // (12 + 18 + 6) / 3 = 12 — not the 36-hour monthly total.
        XCTAssertEqual(juneBucket.wearHours, 12, accuracy: 0.001)
        XCTAssertTrue(juneBucket.hasData)
        // Practice is a sum across the month's days.
        XCTAssertEqual(juneBucket.practiceMinutes, 60, accuracy: 0.001)
        XCTAssertEqual(s.sessionCount, 3)
    }

    /// Days the strap was off are absent from the bucket mean, not counted as
    /// zero — the same rule `avgWearHours` uses, so the bars and the caption
    /// above them can never disagree.
    func testSixMonthBucketWearIgnoresDaysWithNoRollup() {
        // Two worn days in a 30-day month.
        let june = [rollup(day(2026, 6, 10), wearSeconds: 3600 * 14),
                    rollup(day(2026, 6, 20), wearSeconds: 3600 * 10)]
        let s = ConsistencyBuilder.build(range: sixMonth, activities: [], rollups: june,
                                         today: day(2026, 7, 28), calendar: cal)

        let juneBucket = s.buckets.first { $0.bucket.start == day(2026, 6, 1) }!
        XCTAssertEqual(juneBucket.wearHours, 12, accuracy: 0.001)   // not 24/30
        // The caption over the row is the same quantity on the same rule.
        XCTAssertEqual(s.avgWearHours, 12, accuracy: 0.001)
    }

    /// A month with no rollup at all is flat zero and flagged as dataless, so
    /// the axis-label rule can tell it apart from a month measured at zero.
    func testSixMonthBucketWithNoRollupsIsZeroAndHasNoData() {
        let june = [rollup(day(2026, 6, 10), wearSeconds: 3600 * 14)]
        let s = ConsistencyBuilder.build(range: sixMonth, activities: [], rollups: june,
                                         today: day(2026, 7, 28), calendar: cal)

        let march = s.buckets.first { $0.bucket.start == day(2026, 3, 1) }!
        XCTAssertEqual(march.wearHours, 0, accuracy: 0.001)
        XCTAssertFalse(march.hasData)
        XCTAssertTrue(s.buckets.first { $0.bucket.start == day(2026, 6, 1) }!.hasData)
    }

    /// `wearDayCount` is `wearHours`'s own denominator, carried on the bucket
    /// so a sparse 6M month (built on few worn days) can be told apart
    /// downstream from a well-covered one, even though both can produce a
    /// similar-looking mean.
    func testBucketCarriesWearDayCount() {
        let june = [rollup(day(2026, 6, 10), wearSeconds: 3600 * 14),
                    rollup(day(2026, 6, 20), wearSeconds: 3600 * 10)]
        let s = ConsistencyBuilder.build(range: sixMonth, activities: [], rollups: june,
                                         today: day(2026, 7, 28), calendar: cal)
        let juneBucket = s.buckets.first { $0.bucket.start == day(2026, 6, 1) }!
        XCTAssertEqual(juneBucket.wearDayCount, 2)
        let march = s.buckets.first { $0.bucket.start == day(2026, 3, 1) }!
        XCTAssertEqual(march.wearDayCount, 0)
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
