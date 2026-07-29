import Foundation

/// One bar: a bucket and the value behind it.
struct TrackBar: Identifiable, Equatable {
    let bucket: TrackBucket
    let value:  Double?

    var id: Date { bucket.start }
}

/// A short horizontal rule spanning several bars, drawn over the month view so
/// ~30 daily bars stay readable without a number on every one.
struct TrackOverlaySegment: Identifiable, Equatable {
    let start: Date
    let end:   Date
    let value: Double

    var id: Date { start }
}

/// Everything one metric card renders for one page.
struct TrackSeries: Equatable {
    let bars:                [TrackBar]
    let average:             Double?
    /// Benefit-signed change vs the prior page — positive always means better.
    let deltaPct:            Double?
    let reference:           Double
    let referenceIsPersonal: Bool
    let overlay:             [TrackOverlaySegment]
    let betterCount:         Int
    let presentCount:        Int
    let summary:             String
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

    static func bars(spec: TrackMetricSpec, range: TrackRange,
                     rollups: [DailyRollup]) -> [TrackBar] {
        range.buckets.map { bucket in
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

    // MARK: Weekly overlay

    /// Groups daily bars by calendar week and returns the mean of each week's
    /// present values.
    static func weeklyOverlay(bars: [TrackBar],
                              calendar cal: Calendar = .current) -> [TrackOverlaySegment] {
        var groups: [Date: [TrackBar]] = [:]
        for bar in bars {
            let weekStart = cal.dateInterval(of: .weekOfYear, for: bar.bucket.start)?.start
                ?? bar.bucket.start
            groups[weekStart, default: []].append(bar)
        }
        return groups.keys.sorted().compactMap { weekStart in
            let group  = groups[weekStart]!.sorted { $0.bucket.start < $1.bucket.start }
            let values = group.compactMap(\.value)
            guard !values.isEmpty else { return nil }
            return TrackOverlaySegment(start: group.first!.bucket.start,
                                       end:   group.last!.bucket.end,
                                       value: values.reduce(0, +) / Double(values.count))
        }
    }

    // MARK: Series

    static func series(spec: TrackMetricSpec, range: TrackRange, priorRange: TrackRange,
                       rollups: [DailyRollup], asOf: Date,
                       calendar cal: Calendar = .current) -> TrackSeries {
        // Named `currentBars` rather than `bars` so this local doesn't shadow
        // the static `bars(spec:range:rollups:)` function before the prior
        // range's bars are computed below.
        let currentBars = bars(spec: spec, range: range, rollups: rollups)
        let present = currentBars.compactMap(\.value)
        let average = present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)

        let priorBars    = bars(spec: spec, range: priorRange, rollups: rollups)
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

        let overlay = range.period == .month ? weeklyOverlay(bars: currentBars, calendar: cal) : []

        return TrackSeries(
            bars: currentBars, average: average, deltaPct: delta,
            reference: reference, referenceIsPersonal: isPersonal,
            overlay: overlay, betterCount: betterCount, presentCount: present.count,
            summary: summary(period: range.period, better: betterCount,
                             total: present.count, isPersonal: isPersonal))
    }

    /// "5 of 7 days better than your baseline." — phrased as *better* rather
    /// than *above* because for Inner Noise and Stress Balance a lower value
    /// is the good outcome.
    private static func summary(period: TrackPeriod, better: Int,
                                total: Int, isPersonal: Bool) -> String {
        guard total > 0 else { return "No data this period." }
        let noun = total == 1 ? period.bucketNoun.singular : period.bucketNoun.plural
        let ref  = isPersonal ? "your baseline" : "typical"
        return "\(better) of \(total) \(noun) better than \(ref)."
    }
}
