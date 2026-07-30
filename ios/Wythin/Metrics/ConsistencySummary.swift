import Foundation

/// A value-type view of one `ActivityLog`, so the builder stays pure and
/// testable without a `ModelContext`.
struct ActivitySpan: Equatable {
    let startedAt: Date
    let endedAt:   Date?
}

/// Practice effort and strap coverage for one Track page.
///
/// Wear earns its place beside practice: without it a missing bar in the
/// charts above reads as a physiological event rather than a day the strap
/// was off.
struct ConsistencySummary: Equatable {

    struct Bucket: Identifiable, Equatable {
        let bucket:          TrackBucket
        /// Total practice over the bucket — minutes add up across days, and
        /// the row's stat is a total too.
        let practiceMinutes: Double
        /// **Mean daily** wear over the bucket, not the bucket's total. A 6M
        /// bucket is a whole calendar month, so summing would print ~430
        /// under a row captioned `avg h/day`; a W or M bucket is a single day,
        /// where the two are identical. Averaging in every period keeps the
        /// bars, the caption and the charts above on one scale.
        let wearHours:       Double
        /// Whether any day in this bucket produced a rollup at all — the
        /// consistency analogue of a metric bar's `value != nil`. `wearHours`
        /// alone cannot say: a measured zero and an absent day are both 0.
        let hasData:         Bool
        /// Days in this bucket with a wear rollup. `wearHours` is a mean over
        /// exactly these days — this is that mean's denominator, kept around
        /// so a 6M bucket built on too few of them (see
        /// `TrackSeriesBuilder.minDaysPerMonthBucket`) can be told apart from
        /// one that's actually well covered.
        let wearDayCount:    Int

        var id: Date { bucket.start }
    }

    let buckets:              [Bucket]
    let sessionCount:         Int
    let totalPracticeMinutes: Double
    /// Mean over days that have data — days with no rollup are absent, not zero.
    let avgWearHours:         Double
    let streak:               StreakResult
}

enum ConsistencyBuilder {

    /// Practice comes from `ActivityLog`, never `HRVSession`: sessions are
    /// auto-created for background all-day recording, so they measure strap
    /// wear rather than deliberate practice.
    static func build(range: TrackRange, activities: [ActivitySpan],
                      rollups: [DailyRollup], today: Date,
                      calendar cal: Calendar = .current) -> ConsistencySummary {

        // An activity is attributed whole to the day it started on — splitting
        // a session across midnight would report two practices where there was one.
        var minutesByDay: [Date: Double] = [:]
        var practiceDays: Set<Date> = []
        var counted = 0

        for a in activities {
            guard let ended = a.endedAt else { continue }
            let day = cal.startOfDay(for: a.startedAt)
            practiceDays.insert(day)
            guard a.startedAt >= range.start, a.startedAt < range.end else { continue }
            minutesByDay[day, default: 0] += ended.timeIntervalSince(a.startedAt) / 60
            counted += 1
        }

        let wearByDay = Dictionary(uniqueKeysWithValues:
            rollups.map { ($0.day, $0.wearSeconds / 3600) })

        let buckets = range.buckets.map { bucket -> ConsistencySummary.Bucket in
            let days = TrackRangeBuilder.dayStarts(from: bucket.start, to: bucket.end, calendar: cal)
            // Days that actually produced a rollup. Used as the wear
            // denominator so the bucket reads as hours *per day*, matching
            // both the row's `avg h/day` caption and `avgWearHours` below —
            // which averages over days with data, treating a strap-off day as
            // absent rather than as a zero that drags the mean down.
            //
            // It also puts this row on the same rule as the metric charts
            // stacked above it: `TrackSeriesBuilder.bars` takes the unweighted
            // mean of the daily values in a bucket, so a month is aggregated
            // one way on this screen, not two.
            let worn = days.compactMap { wearByDay[$0] }
            return ConsistencySummary.Bucket(
                bucket:          bucket,
                practiceMinutes: days.reduce(0) { $0 + (minutesByDay[$1] ?? 0) },
                wearHours:       worn.isEmpty ? 0 : worn.reduce(0, +) / Double(worn.count),
                hasData:         !worn.isEmpty,
                wearDayCount:    worn.count)
        }

        let wornDays = range.days.compactMap { wearByDay[$0] }

        // The streak is period-scoped like everything else on this card, so
        // paging to an earlier page must evaluate it as of that page, not
        // today. For the *current* page `range.end` is in the future — end
        // of this week/month/6M span — and `StreakCompute.evaluate` walks
        // backwards from the date it's given, so handing it a future date
        // would look for practice on a day that hasn't happened yet and
        // collapse the streak to 0. Clamp to whichever is earlier.
        let lastDayOfRange = cal.date(byAdding: .day, value: -1, to: range.end) ?? range.start
        let streakAsOf = min(lastDayOfRange, today)

        return ConsistencySummary(
            buckets:              buckets,
            sessionCount:         counted,
            totalPracticeMinutes: minutesByDay.values.reduce(0, +),
            avgWearHours:         wornDays.isEmpty
                                    ? 0 : wornDays.reduce(0, +) / Double(wornDays.count),
            streak:               StreakCompute.evaluate(days: practiceDays,
                                                         today: streakAsOf, calendar: cal))
    }
}
