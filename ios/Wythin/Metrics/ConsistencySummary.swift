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
        let practiceMinutes: Double
        let wearHours:       Double

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
            return ConsistencySummary.Bucket(
                bucket:          bucket,
                practiceMinutes: days.reduce(0) { $0 + (minutesByDay[$1] ?? 0) },
                wearHours:       days.reduce(0) { $0 + (wearByDay[$1] ?? 0) })
        }

        let wornDays = range.days.compactMap { wearByDay[$0] }

        return ConsistencySummary(
            buckets:              buckets,
            sessionCount:         counted,
            totalPracticeMinutes: minutesByDay.values.reduce(0, +),
            avgWearHours:         wornDays.isEmpty
                                    ? 0 : wornDays.reduce(0, +) / Double(wornDays.count),
            streak:               StreakCompute.evaluate(days: practiceDays,
                                                         today: today, calendar: cal))
    }
}
