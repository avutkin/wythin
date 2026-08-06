import SwiftUI
import Charts

/// Practice effort and strap coverage for the period. Wear sits beside
/// practice because it explains gaps in the charts above: without it a missing
/// bar reads as a physiological event rather than a day the strap was off.
struct ConsistencyCard: View {
    let summary: ConsistencySummary
    let period:  TrackPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONSISTENCY")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            row(title: "PRACTICE",
                unit: unitCaption(perDay: "MIN"),
                stats: practiceStats,
                values: summary.buckets.map(\.practiceMinutes),
                color: Theme.accent,
                format: { $0 < 1 ? "" : String(format: "%.0f", $0) })

            row(title: "WEAR",
                unit: unitCaption(perDay: "H"),
                stats: String(format: "avg %.1f h/day", summary.avgWearHours),
                values: summary.buckets.map { ConsistencyCard.wearDisplayValue($0, period: period) },
                color: Theme.hrv,
                format: { $0 < 0.5 ? "" : String(format: "%.0f", $0) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.horizontal)
    }

    /// The WEAR row's plotted value for one bucket, with a 6M bucket that has
    /// too few worn days (`TrackSeriesBuilder.minDaysPerMonthBucket`, shared
    /// with the charts above so the two rules can't drift) treated as
    /// absent rather than plotted at its true mean.
    ///
    /// Suppressing it — rather than dimming it or printing the day count —
    /// reuses the row's own existing "no real value" language: a suppressed
    /// bucket falls back to the same grey floor-stub a measured zero already
    /// gets (see `row(...)` below), with no number above it. That is exactly
    /// what this card exists to prevent from being confused with a real
    /// reading, and it keeps the wear row visually in agreement with the
    /// blank chart bars directly above it for the same sparse month, rather
    /// than introducing a third visual language the row doesn't already
    /// speak. W and M buckets are always a single day — `wearDayCount` there
    /// is 0 or 1 — so this only ever engages in 6M.
    ///
    /// A free function of `(bucket, period)` rather than an instance method
    /// so the presentation rule is directly unit-testable without going
    /// through SwiftUI rendering.
    static func wearDisplayValue(_ bucket: ConsistencySummary.Bucket,
                                 period: TrackPeriod) -> Double {
        guard period == .sixMonth,
              bucket.wearDayCount > 0,
              bucket.wearDayCount < TrackSeriesBuilder.minDaysPerMonthBucket
        else { return bucket.wearHours }
        return 0
    }

    /// What one bar counts, said next to the row title. Without it the numbers
    /// printed over the bars are bare — "45" over a row headed PRACTICE reads
    /// just as plausibly as 45 sessions as 45 minutes, and the stat line
    /// beside it quotes both a session count and a minute total, so it
    /// resolves nothing. A 6M bar is a whole month of practice, not a day of
    /// it, so the caption has to follow the period rather than be a constant.
    private func unitCaption(perDay unit: String) -> String {
        switch period {
        case .week, .month: return "\(unit)/DAY"
        case .sixMonth:     return unit == "H" ? "H/DAY" : "\(unit)/MONTH"
        }
    }

    /// "26 sessions · 345 min total" — `total` because the bars above are
    /// per-bucket, and without it the two numbers read as alternative
    /// measures of the same thing rather than a count and its sum.
    private var practiceStats: String {
        let sessions = "\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")"
        let minutes  = String(format: "%.0f min total", summary.totalPracticeMinutes)
        let streak   = summary.streak.current > 0 ? "  🔥 \(summary.streak.current)d" : ""
        return "\(sessions) · \(minutes)\(streak)"
    }

    private func row(title: String, unit: String, stats: String, values: [Double],
                     color: Color, format: @escaping (Double) -> String) -> some View {
        // Charts anchors BarMark at zero, so a `value == 0` bar has zero
        // height and is invisible no matter its color — which would defeat
        // this card's whole purpose of telling "measured zero" apart from
        // "no data". Plot at least a small stub instead, sized off this
        // row's own scale (3% of its max) so it reads as proportionally
        // tiny rather than a real value. `foregroundStyle` and the label
        // stay keyed on the true `value`, so a stub is still grey and
        // unlabeled even though its plotted height is nonzero.
        //
        // If every value in the row is zero there is no scale to be
        // proportional to — fall back to a fixed unit purely so the row
        // renders a visible line of grey stubs instead of a blank plot.
        // The fallback is chosen so the stub-to-domain ratio matches the
        // non-degenerate case (3% / 1.25 headroom either way).
        let rowMax    = values.max() ?? 0
        let scale     = rowMax > 0 ? rowMax : ConsistencyCard.zeroRowScale
        let floor     = scale * 0.03
        let domainTop = scale * 1.25

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.text)
                Text(unit)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.dim.opacity(0.8))
                Spacer()
                Text(stats)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            Chart {
                ForEach(Array(zip(summary.buckets, values)), id: \.0.id) { bucket, value in
                    BarMark(
                        x: .value("Bucket", bucket.bucket.start, unit: xUnit),
                        y: .value(title, max(value, floor)),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(value > 0 ? color.opacity(0.85) : Theme.surface)
                    .annotation(position: .top, spacing: 1) {
                        if showLabels {
                            Text(format(value))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .frame(height: 54)
            // Headroom so the tallest bar's value annotation is not
            // clipped, matching `TrackMetricChartCard.yDomain` — these rows
            // are 54pt tall versus that card's 132pt, so a top-anchored
            // label is at greater risk of clipping here, not less.
            .chartYScale(domain: 0...domainTop)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: summary.buckets.map(\.bucket.start)) { value in
                    if let d = value.as(Date.self),
                       let b = summary.buckets.first(where: { $0.bucket.start == d }),
                       showAxisLabel(b.bucket.start) {
                        AxisValueLabel {
                            Text(b.bucket.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
        }
    }

    /// Fallback scale for an all-zero row, purely to give the floor/domain
    /// math something to be proportional to when the real data has none.
    private static let zeroRowScale: Double = 1

    private var xUnit: Calendar.Component { period == .sixMonth ? .month : .day }

    /// Thirty labels do not fit across a phone; the month view drops them.
    private var showLabels: Bool { period != .month }

    private func showAxisLabel(_ d: Date) -> Bool {
        guard period == .month else { return true }
        // Every fifth day, so a 31-day axis stays readable — matches
        // `TrackMetricChartCard.showAxisLabel`.
        if Calendar.current.component(.day, from: d) % 5 == 1 { return true }
        // That sibling also ORs in its most recent bar *with a value*
        // (`TrackMetricChartCard.showAxisLabel`). `summary.buckets.last` is
        // not the same thing: every bucket here carries a value, including
        // days later this month that have not happened yet — so on the 12th
        // this card labelled the 31st while the charts directly above it
        // labelled the 12th, two stacked axes disagreeing about the same
        // month. `hasData` is the analogue of the sibling's `value != nil`,
        // so both now land on the most recent day with real data. When
        // nothing has data the optional is nil and, exactly as in the
        // sibling, no extra label is added.
        return d == summary.buckets.last(where: \.hasData)?.bucket.start
    }
}
