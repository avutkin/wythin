import Foundation

/// The three windows the Track screen pages through.
enum TrackPeriod: String, CaseIterable, Identifiable {
    case week     = "W"
    case month    = "M"
    case sixMonth = "6M"

    var id: String { rawValue }

    /// Wire value for the macro-read insight payload.
    var apiValue: String {
        switch self {
        case .week:     return "week"
        case .month:    return "month"
        case .sixMonth: return "six_month"
        }
    }

    /// What one bar covers — used for pluralised copy.
    var bucketNoun: (singular: String, plural: String) {
        self == .sixMonth ? ("month", "months") : ("day", "days")
    }
}

/// One x-axis slot: a single day (W, M) or a calendar month (6M).
/// `start` is inclusive, `end` exclusive.
struct TrackBucket: Equatable, Identifiable {
    let start: Date
    let end:   Date
    let label: String

    var id: Date { start }
}

/// One page of a period. `offset` 0 is the current page; 1 is one page back.
/// `start` is inclusive, `end` exclusive.
struct TrackRange: Equatable {
    let period:  TrackPeriod
    let offset:  Int
    let start:   Date
    let end:     Date
    /// Every local day the page covers — what `TrackCache.refresh` needs.
    ///
    /// Stored rather than computed on demand: enumerating days here with
    /// `Calendar.current` while the range itself was built from an injected
    /// calendar would produce day boundaries that don't line up with the
    /// buckets — silently, and only in whatever timezone differs.
    let days:    [Date]
    let buckets: [TrackBucket]
    let label:   String

    var isCurrent: Bool { offset == 0 }
}

enum TrackRangeBuilder {

    static func range(period: TrackPeriod, offset: Int, today: Date,
                      calendar: Calendar = .current) -> TrackRange {
        switch period {
        case .week:     return week(offset: offset, today: today, calendar: calendar)
        case .month:    return month(offset: offset, today: today, calendar: calendar)
        case .sixMonth: return sixMonth(offset: offset, today: today, calendar: calendar)
        }
    }

    // MARK: Week

    private static func week(offset: Int, today: Date, calendar cal: Calendar) -> TrackRange {
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let start    = cal.date(byAdding: .weekOfYear, value: -offset, to: thisWeek)!
        let end      = cal.date(byAdding: .weekOfYear, value: 1, to: start)!

        let buckets = dayBuckets(from: start, to: end, calendar: cal) { d in
            // Narrow weekday: "M", "T", …
            String(fmt("EEEEE", cal).string(from: d).uppercased().prefix(1))
        }
        let last = cal.date(byAdding: .day, value: -1, to: end)!
        return TrackRange(period: .week, offset: offset, start: start, end: end,
                          days: buckets.map(\.start), buckets: buckets,
                          label: "\(fmt("MMM d", cal).string(from: start).uppercased()) – "
                               + "\(fmt("MMM d", cal).string(from: last).uppercased())")
    }

    // MARK: Month

    private static func month(offset: Int, today: Date, calendar cal: Calendar) -> TrackRange {
        let thisMonth = cal.dateInterval(of: .month, for: today)!.start
        let start     = cal.date(byAdding: .month, value: -offset, to: thisMonth)!
        let end       = cal.date(byAdding: .month, value: 1, to: start)!

        let buckets = dayBuckets(from: start, to: end, calendar: cal) { d in
            String(cal.component(.day, from: d))
        }
        return TrackRange(period: .month, offset: offset, start: start, end: end,
                          days: buckets.map(\.start), buckets: buckets,
                          label: fmt("MMMM yyyy", cal).string(from: start).uppercased())
    }

    // MARK: Six months

    private static func sixMonth(offset: Int, today: Date, calendar cal: Calendar) -> TrackRange {
        let thisMonth = cal.dateInterval(of: .month, for: today)!.start
        let end       = cal.date(byAdding: .month, value: 1 - offset * 6, to: thisMonth)!
        let start     = cal.date(byAdding: .month, value: -6, to: end)!

        var buckets: [TrackBucket] = []
        var m = start
        while m < end {
            let next = cal.date(byAdding: .month, value: 1, to: m)!
            buckets.append(TrackBucket(start: m, end: next,
                                       label: fmt("MMM", cal).string(from: m).uppercased()))
            m = next
        }
        let last = cal.date(byAdding: .month, value: -1, to: end)!
        // Buckets are months here, but `days` is still every day in the span —
        // the rollup cache is day-granular whatever the bucket size.
        return TrackRange(period: .sixMonth, offset: offset, start: start, end: end,
                          days: dayStarts(from: start, to: end, calendar: cal),
                          buckets: buckets,
                          label: "\(fmt("MMM", cal).string(from: start).uppercased()) – "
                               + "\(fmt("MMM yyyy", cal).string(from: last).uppercased())")
    }

    // MARK: Helpers

    /// One bucket per calendar day. Stepping by `.day` rather than adding
    /// 86,400 s keeps DST-shortened and -lengthened days at one bucket each.
    private static func dayBuckets(from start: Date, to end: Date, calendar cal: Calendar,
                                   label: (Date) -> String) -> [TrackBucket] {
        var out: [TrackBucket] = []
        var d = start
        while d < end {
            let next = cal.date(byAdding: .day, value: 1, to: d)!
            out.append(TrackBucket(start: d, end: next, label: label(d)))
            d = next
        }
        return out
    }

    /// Day-start dates spanning `[start, end)`, on the given calendar.
    static func dayStarts(from start: Date, to end: Date, calendar cal: Calendar) -> [Date] {
        var out: [Date] = []
        var d = start
        while d < end {
            out.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    private static func fmt(_ format: String, _ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar   = cal
        f.timeZone   = cal.timeZone
        f.locale     = cal.locale ?? Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
