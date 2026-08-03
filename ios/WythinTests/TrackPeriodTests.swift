import XCTest
@testable import Wythin

final class TrackPeriodTests: XCTestCase {

    /// Fixed calendar so weekday boundaries and DST are deterministic.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2   // Monday
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Week

    func testWeekCoversMondayThroughSunday() {
        // 2026-07-28 is a Tuesday.
        let r = TrackRangeBuilder.range(period: .week, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(r.buckets.count, 7)
        XCTAssertEqual(r.start, cal.startOfDay(for: date(2026, 7, 27)))   // Monday
        XCTAssertEqual(r.buckets.last!.start, cal.startOfDay(for: date(2026, 8, 2)))
    }

    func testWeekOffsetGoesBackSevenDays() {
        let now  = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        let prev = TrackRangeBuilder.range(period: .week, offset: 1, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(cal.dateComponents([.day], from: prev.start, to: now.start).day, 7)
        XCTAssertEqual(prev.buckets.count, 7)
    }

    func testWeekSpanningDSTStillHasSevenBuckets() {
        // US DST starts Sunday 2026-03-08; that week is 167 hours long.
        let r = TrackRangeBuilder.range(period: .week, offset: 0,
                                        today: date(2026, 3, 4), calendar: cal)
        XCTAssertEqual(r.buckets.count, 7)
    }

    // MARK: Month

    func testMonthHasOneBucketPerDay() {
        let r = TrackRangeBuilder.range(period: .month, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(r.buckets.count, 31)
        XCTAssertEqual(r.start, cal.startOfDay(for: date(2026, 7, 1)))
    }

    func testFebruaryLengthsAreCorrect() {
        let common = TrackRangeBuilder.range(period: .month, offset: 0,
                                             today: date(2026, 2, 15), calendar: cal)
        XCTAssertEqual(common.buckets.count, 28)

        let leap = TrackRangeBuilder.range(period: .month, offset: 0,
                                           today: date(2024, 2, 15), calendar: cal)
        XCTAssertEqual(leap.buckets.count, 29)
    }

    func testMonthOffsetCrossesTheYearBoundary() {
        let r = TrackRangeBuilder.range(period: .month, offset: 1,
                                        today: date(2026, 1, 15), calendar: cal)
        XCTAssertEqual(r.start, cal.startOfDay(for: date(2025, 12, 1)))
        XCTAssertEqual(r.buckets.count, 31)
    }

    // MARK: Six months

    func testSixMonthHasSixMonthlyBucketsEndingThisMonth() {
        let r = TrackRangeBuilder.range(period: .sixMonth, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(r.buckets.count, 6)
        XCTAssertEqual(r.buckets.first!.start, cal.startOfDay(for: date(2026, 2, 1)))
        XCTAssertEqual(r.buckets.last!.start, cal.startOfDay(for: date(2026, 7, 1)))
        // "Jul", not "JUL" — see the label-building comment in
        // `TrackRangeBuilder.sixMonth`.
        XCTAssertEqual(r.buckets.last!.label, "Jul")
    }

    func testSixMonthOffsetDoesNotOverlap() {
        let now  = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: date(2026, 7, 28), calendar: cal)
        let prev = TrackRangeBuilder.range(period: .sixMonth, offset: 1, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(prev.end, now.start)
        XCTAssertEqual(prev.buckets.first!.start, cal.startOfDay(for: date(2025, 8, 1)))
    }

    // MARK: Buckets and labels

    func testBucketEndIsExclusiveAndContiguous() {
        let r = TrackRangeBuilder.range(period: .week, offset: 0,
                                        today: date(2026, 7, 28), calendar: cal)
        for (a, b) in zip(r.buckets, r.buckets.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
        XCTAssertEqual(r.buckets.last!.end, r.end)
    }

    func testLabelsAreHumanReadable() {
        let w = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(w.label, "JUL 27 – AUG 2")

        let m = TrackRangeBuilder.range(period: .month, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(m.label, "JULY 2026")

        let s = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.label, "FEB – JUL 2026")
    }

    func testDaysUseTheInjectedCalendarNotTheLocalOne() {
        // `days` must line up exactly with the bucket starts, or every
        // rollup lookup misses by a timezone offset.
        let w = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(w.days, w.buckets.map(\.start))

        // 6M buckets are months, but `days` is still every day in the span.
        let s = TrackRangeBuilder.range(period: .sixMonth, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(s.days.count, 181)          // Feb 1 – Jul 31 2026
        XCTAssertEqual(s.days.first, s.start)
        XCTAssertEqual(s.days.last, cal.startOfDay(for: date(2026, 7, 31)))
    }

    func testDayBucketLabels() {
        // Week buckets carry the weekday initial *and* the date — a bare "S"
        // can't tell Saturday from Sunday, or one Tuesday from a Tuesday in
        // an adjacent week.
        let w = TrackRangeBuilder.range(period: .week, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(w.buckets.map(\.label),
                       ["M 7-27", "T 7-28", "W 7-29", "T 7-30", "F 7-31", "S 8-1", "S 8-2"])

        let m = TrackRangeBuilder.range(period: .month, offset: 0, today: date(2026, 7, 28), calendar: cal)
        XCTAssertEqual(m.buckets.first!.label, "1")
        XCTAssertEqual(m.buckets.last!.label, "31")
    }

    // MARK: shortDateLabel

    func testShortDateLabelHasNoLeadingZeros() {
        XCTAssertEqual(TrackRangeBuilder.shortDateLabel(date(2026, 8, 30), calendar: cal), "8-30")
        // Single-digit month AND single-digit day, the case a naive
        // DateFormatter pattern is most likely to get wrong in one locale
        // or another.
        XCTAssertEqual(TrackRangeBuilder.shortDateLabel(date(2026, 1, 5), calendar: cal), "1-5")
        XCTAssertEqual(TrackRangeBuilder.shortDateLabel(date(2026, 11, 3), calendar: cal), "11-3")
        XCTAssertEqual(TrackRangeBuilder.shortDateLabel(date(2026, 12, 25), calendar: cal), "12-25")
    }

    // MARK: priorNoun

    func testPriorNounMatchesEachPeriod() {
        XCTAssertEqual(TrackPeriod.week.priorNoun, "week")
        XCTAssertEqual(TrackPeriod.month.priorNoun, "month")
        XCTAssertEqual(TrackPeriod.sixMonth.priorNoun, "6 months")
    }
}
