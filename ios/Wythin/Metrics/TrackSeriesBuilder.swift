import Foundation

/// One bar: a bucket and the value behind it.
struct TrackBar: Identifiable, Equatable {
    let bucket: TrackBucket
    let value:  Double?

    var id: Date { bucket.start }
}

/// One horizontal line drawn on a metric's chart: a value and the short
/// legend text describing what it is.
///
/// A list rather than a single value/flag pair, because the chart is meant
/// to grow a second line later: a cross-user peer-group average, once the
/// server can supply one (it can't yet — that needs a cross-user aggregate
/// that isn't deployed). Today `TrackSeries.referenceLines` holds at most
/// one entry, but nothing about rendering or building it assumes that stays
/// true, so adding the second line later is additive rather than a reshape.
struct TrackReferenceLine: Identifiable, Equatable {
    let value: Double
    let label: String
    var id: String { label }
}

/// Everything one metric card renders for one page.
struct TrackSeries: Equatable {
    let bars:                [TrackBar]
    let average:             Double?
    /// Benefit-signed change vs the prior page — positive always means better.
    let deltaPct:            Double?

    /// The person's own 90-day median, or a fixed physiological norm when
    /// they don't have enough history yet (`referenceIsPersonal` says
    /// which). This pair — plus `betterCount`/`presentCount` below, counted
    /// against it — feeds only `MacroTrendPayload`, the macro-trend insight
    /// sent to the server: a long-run "is this person's typical" comparison,
    /// deliberately left alone here. `referenceLines` below is the
    /// short-run, period-over-period comparison actually drawn on screen;
    /// the two can legitimately disagree; if `reference`'s meaning ever
    /// needs to change, that's a payload/prompt change on its own, not a
    /// side effect of a chart rework.
    let reference:           Double
    let referenceIsPersonal: Bool
    let betterCount:         Int
    let presentCount:        Int

    /// The line(s) actually drawn on the chart — the previous period's
    /// average, today. Empty when there is no prior period to compare
    /// against at all (the first page a person ever opens), rather than
    /// falling back to some other value that isn't what the line claims to be.
    let referenceLines: [TrackReferenceLine]
    /// "N of N days better than prior week." — the footer copy, phrased
    /// against `referenceLines` (not `reference`; see its doc above for why
    /// they can differ).
    let summary: String
}

enum TrackSeriesBuilder {

    /// Below this many of the user's own days, the reference falls back to a
    /// fixed physiological norm.
    static let minBaselineDays = 14
    static let baselineWindowDays = 90
    /// A monthly bar built on fewer days than this is suppressed rather than
    /// shown as if it were representative.
    static let minDaysPerMonthBucket = 5

    // MARK: Bars

    /// `calendar` only matters for the month page, which regroups its daily
    /// buckets into calendar weeks below — every other period's buckets
    /// already come straight out of `range.buckets` at the granularity the
    /// chart wants, so it's unused there.
    static func bars(spec: TrackMetricSpec, range: TrackRange, rollups: [DailyRollup],
                     calendar cal: Calendar = .current) -> [TrackBar] {
        let daily = range.buckets.map { bucket -> TrackBar in
            let values = rollups
                .filter { $0.day >= bucket.start && $0.day < bucket.end }
                .compactMap { spec.rollup($0) }

            let minDays = range.period == .sixMonth ? minDaysPerMonthBucket : 1
            guard values.count >= minDays else {
                return TrackBar(bucket: bucket, value: nil)
            }
            // Unweighted mean of daily means: a day is a day, so an 18-hour
            // wear day cannot outweigh a 6-hour one.
            return TrackBar(bucket: bucket,
                            value: values.reduce(0, +) / Double(values.count))
        }
        // The month page charts weekly bars, not daily ones — see
        // `weekBars` for how the month's first and last, usually-partial
        // calendar weeks are handled.
        guard range.period == .month else { return daily }
        return weekBars(dailyBars: daily, calendar: cal)
    }

    /// Groups a month's daily bars into calendar weeks (Monday-first, or
    /// whatever the injected calendar's `firstWeekday` says) and collapses
    /// each into one bar: the unweighted mean of that week's present days,
    /// nil when none of them are.
    ///
    /// A month's first and last calendar week essentially never align with
    /// the 1st or the last day of the month — e.g. a month starting on a
    /// Thursday puts that week's Monday–Wednesday in the *previous* month.
    /// Rather than stretch the edge bucket out to a full 7 days (which would
    /// double-count those days against the neighbouring month's own page) or
    /// drop them, each edge bucket is sized to only the days this month
    /// actually contributed — 1–6 days instead of 7 — and averaged over just
    /// those. Every day in the month still lands in exactly one bucket, and
    /// every bucket is a real calendar week (the one a person would actually
    /// call "last week"), rather than an arbitrary 7-day slice counted from
    /// the 1st that drifts out of alignment with the real week as the month
    /// goes on.
    static func weekBars(dailyBars: [TrackBar],
                        calendar cal: Calendar = .current) -> [TrackBar] {
        var groups: [Date: [TrackBar]] = [:]
        for bar in dailyBars {
            let weekStart = cal.dateInterval(of: .weekOfYear, for: bar.bucket.start)?.start
                ?? bar.bucket.start
            groups[weekStart, default: []].append(bar)
        }
        return groups.keys.sorted().map { weekStart in
            let group  = groups[weekStart]!.sorted { $0.bucket.start < $1.bucket.start }
            let start  = group.first!.bucket.start
            let end    = group.last!.bucket.end
            let values = group.compactMap(\.value)
            let value: Double? = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            let bucket = TrackBucket(start: start, end: end,
                                     label: TrackRangeBuilder.shortDateLabel(start, calendar: cal))
            return TrackBar(bucket: bucket, value: value)
        }
    }

    // MARK: Baseline

    static func baseline(spec: TrackMetricSpec, rollups: [DailyRollup],
                         asOf: Date, calendar cal: Calendar = .current)
    -> (value: Double, isPersonal: Bool) {
        let cutoff = cal.date(byAdding: .day, value: -baselineWindowDays, to: asOf) ?? .distantPast
        let values = rollups
            .filter { $0.day > cutoff && $0.day <= asOf }
            .compactMap { spec.rollup($0) }
            .sorted()

        guard values.count >= minBaselineDays else {
            return (spec.fallbackReference, false)
        }
        let mid = values.count / 2
        let median = values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2
            : values[mid]
        return (median, true)
    }

    // MARK: Series

    static func series(spec: TrackMetricSpec, range: TrackRange, priorRange: TrackRange,
                       rollups: [DailyRollup], asOf: Date,
                       calendar cal: Calendar = .current) -> TrackSeries {
        // Named `currentBars` rather than `bars` so this local doesn't shadow
        // the static `bars(spec:range:rollups:)` function before the prior
        // range's bars are computed below.
        let currentBars = bars(spec: spec, range: range, rollups: rollups, calendar: cal)
        let present = currentBars.compactMap(\.value)
        let average = present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)

        let priorBars    = bars(spec: spec, range: priorRange, rollups: rollups, calendar: cal)
        let priorPresent = priorBars.compactMap(\.value)
        let priorAverage = priorPresent.isEmpty
            ? nil : priorPresent.reduce(0, +) / Double(priorPresent.count)

        // Reuses the shared benefit-signed formula so a fall in Inner Noise
        // reads as an improvement.
        let delta = spec.def.benefitDelta(current: average, base: priorAverage)

        let (reference, isPersonal) = baseline(spec: spec, rollups: rollups,
                                               asOf: asOf, calendar: cal)
        let refBenefit  = spec.def.direction.benefit(reference)
        let betterCount = present.filter { spec.def.direction.benefit($0) > refBenefit }.count

        // The chart's own reference line: the previous period's average,
        // absent entirely (not defaulted to anything) when there wasn't one.
        let referenceLines: [TrackReferenceLine] = priorAverage.map {
            [TrackReferenceLine(value: $0, label: "prior \(range.period.priorNoun) avg")]
        } ?? []
        let chartBetterCount: Int? = priorAverage.map { prior in
            let priorBenefit = spec.def.direction.benefit(prior)
            return present.filter { spec.def.direction.benefit($0) > priorBenefit }.count
        }

        return TrackSeries(
            bars: currentBars, average: average, deltaPct: delta,
            reference: reference, referenceIsPersonal: isPersonal,
            betterCount: betterCount, presentCount: present.count,
            referenceLines: referenceLines,
            summary: summary(period: range.period, better: chartBetterCount, total: present.count))
    }

    /// "5 of 7 days better than prior week." — phrased as *better* rather
    /// than *above* because for Inner Noise and Stress Balance a lower value
    /// is the good outcome. `better` is nil — not zero — when there is no
    /// prior period to compare against at all, which reads differently from
    /// "0 of 7" (an actual, comparably worse period).
    private static func summary(period: TrackPeriod, better: Int?, total: Int) -> String {
        guard total > 0 else { return "No data this period." }
        guard let better else { return "No prior \(period.priorNoun) to compare yet." }
        let noun = total == 1 ? period.bucketNoun.singular : period.bucketNoun.plural
        return "\(better) of \(total) \(noun) better than prior \(period.priorNoun)."
    }
}
