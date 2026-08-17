import SwiftUI
import Charts

/// One metric's bar chart for one page: header average, benefit-signed delta,
/// bars, and the personal reference line.
///
/// W and 6M print each bar's value on top of it. M can't — it has one bar per
/// day, ~30 of them, and thirty 8pt numbers do not fit across a phone. Its
/// numbers come from the weekly average lines drawn over the bars instead,
/// one per calendar week; any single day's own value is still readable by
/// tapping its bar, which puts it in the header.
struct TrackMetricChartCard: View {
    let spec:   TrackMetricSpec
    let series: TrackSeries
    let period: TrackPeriod
    @Binding var selectedBucket: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chart
            footer
        }
        .cardStyle()
        .padding(.horizontal)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.def.label.uppercased())
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.text)
                    Text(spec.def.techFull.isEmpty ? spec.def.techLabel : spec.def.techFull)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                }
                deltaChip
                referenceLegend
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(spec.def.format(headerValue))
                        .font(Theme.mono(20))
                        .foregroundStyle(spec.color)
                    if !spec.def.unit.isEmpty {
                        Text(spec.def.unit)
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                }
                Text(headerCaption)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    /// The selected bar's value when a bar is tapped, otherwise the average.
    private var headerValue: Double? {
        if let sel = selectedBucket,
           let bar = series.bars.first(where: { $0.bucket.start == sel }) {
            return bar.value
        }
        return series.average
    }

    private var headerCaption: String {
        if let sel = selectedBucket,
           let bar = series.bars.first(where: { $0.bucket.start == sel }) {
            return captionFormatter.string(from: bar.bucket.start).uppercased()
        }
        return "AVERAGE"
    }

    private var captionFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = period == .sixMonth ? "MMM yyyy" : "EEE d MMM"
        return f
    }

    /// Below this the chip is suppressed. The label rounds to whole percent,
    /// so -0.4 and +0.2 both print "0%" — but one draws a red ▼ and the other
    /// a green ▲, giving two opposite-looking verdicts for a change the user
    /// cannot distinguish. Nothing is a truer read than a coin-flip arrow.
    private static let minDeltaPct: Double = 0.5

    @ViewBuilder
    private var deltaChip: some View {
        if let d = series.deltaPct, abs(d) >= Self.minDeltaPct {
            let better = d >= 0
            Text("\(better ? "▲" : "▼") \(abs(d), specifier: "%.0f")% vs prior \(period.priorNoun)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(better ? Theme.accent : Theme.warn)
        }
    }

    /// A small legend for the chart's dashed reference line(s) — living in
    /// the header rather than as an in-plot annotation. The line used to
    /// carry its own label anchored at the plot's trailing edge; that
    /// required the plot to reserve a margin for it, which is exactly the
    /// dead space at the right of the bars the card exists to fix. Moving
    /// the label up here instead lets the bars run the full width of the
    /// plot, and reads naturally as a list — ready for a second line
    /// (a peer-group average) later without needing its own new home.
    @ViewBuilder
    private var referenceLegend: some View {
        HStack(spacing: 8) {
            ForEach(series.referenceLines) { line in
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Theme.dim.opacity(0.6))
                        .frame(width: 9, height: 1)
                    Text(line.label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8))
                }
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            // Labelled by `referenceLegend` in the header, not here — see that
            // property's doc for why the label moved off the plot. A `ForEach`
            // rather than one hardcoded RuleMark so a second line can be added
            // to `series.referenceLines` later without touching this view.
            ForEach(series.referenceLines) { line in
                RuleMark(y: .value(line.label, line.value))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }

            ForEach(series.bars) { bar in
                if let v = bar.value {
                    // Anchored at the visible domain's floor rather than a
                    // bare `y:` value (which Swift Charts always anchors at
                    // zero). For zero-based metrics the floor *is* zero, so
                    // this renders identically to before; for index metrics
                    // (Adaptive Capacity, Harmony) whose domain floor sits
                    // well above zero, this is what keeps the bar inside the
                    // plotted band instead of stretching down through it and
                    // out the bottom of the chart.
                    BarMark(
                        x:      .value("Bucket", bar.bucket.start, unit: xUnit),
                        yStart: .value(spec.def.label, barAnchor),
                        yEnd:   .value(spec.def.label, v),
                        width:  barWidth
                    )
                    .cornerRadius(cornerRadius)
                    .foregroundStyle(barColor(bar, value: v))
                    .annotation(position: .top, spacing: 2) {
                        if showsBarValues {
                            Text(spec.def.format(v))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                } else {
                    // Invisible anchor at this bucket's x-position. When every
                    // bar in the page is nil, no *visible* BarMark is ever
                    // emitted, and the value-less RuleMark(y:) above has no
                    // x-position either — so with nothing else, Swift Charts
                    // has no x-domain to resolve the AxisMarks(values:) below
                    // against, and the whole axis (including the "·"
                    // placeholders) renders blank. This keeps every bucket in
                    // the domain the same way a real BarMark would, without
                    // changing how the axis or bars look when data exists.
                    // Uses the same domain-floor anchor as the visible bars
                    // above rather than a bare zero, so it stays inside the
                    // domain for index metrics too.
                    BarMark(x:      .value("Bucket", bar.bucket.start, unit: xUnit),
                            yStart: .value(spec.def.label, barAnchor),
                            yEnd:   .value(spec.def.label, barAnchor))
                        .opacity(0)
                }
            }

            // The month page's weekly means, drawn *after* the bars so they
            // sit on top of them rather than behind. Each spans exactly its
            // own week: `start` is that week's first day and `end` the day
            // after its last, which on the same date scale the bars are
            // placed against lands flush with the outer edges of the first
            // and last bar underneath it. Empty for every other period.
            ForEach(series.weekAverages) { week in
                if let v = week.value {
                    RuleMark(
                        xStart: .value("Week start", week.start),
                        xEnd:   .value("Week end", week.end),
                        y:      .value(spec.def.label, v)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                    .foregroundStyle(spec.color)
                    .annotation(position: .top, spacing: 1) {
                        // On a chip, unlike the bar-top values on W and 6M.
                        // A week's mean sits *inside* its own bars by
                        // definition — roughly half of them rise above it —
                        // so bare text here lands on top of bright green
                        // bars and is unreadable against them.
                        Text(spec.def.format(v))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(spec.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.bg.opacity(0.85)))
                    }
                }
            }
        }
        .frame(height: 132)
        .chartYScale(domain: yDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            if period == .month {
                // One label per calendar week rather than per day: ~30 dates
                // will not fit, and the day-of-month digits they would carry are
                // the least useful thing this axis could say. Each label names
                // the period its week covers ("6–12") and hangs off that
                // week's middle day so it sits centred under the average line
                // and the seven bars it stands for.
                AxisMarks(values: series.weekAverages.map(\.midDay)) { value in
                    if let d = value.as(Date.self),
                       let week = series.weekAverages.first(where: { $0.midDay == d }) {
                        AxisValueLabel {
                            Text(week.value == nil ? "·" : week.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                // Without this the label is offered only the
                                // width Charts thinks is free to the right of
                                // its tick, and the last week — anchored a few
                                // days short of the plot's trailing edge —
                                // truncates to "27–…" even though the whole
                                // "27–31" fits inside the plot.
                                .fixedSize()
                        }
                    }
                }
            } else {
                // W and 6M label every bar — ≤7 of them, so nothing needs
                // thinning to stay legible.
                AxisMarks(values: series.bars.map(\.bucket.start)) { value in
                    if let d = value.as(Date.self),
                       let bar = series.bars.first(where: { $0.bucket.start == d }) {
                        AxisValueLabel {
                            Text(bar.value == nil ? "·" : bar.bucket.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedBucket },
            set: { newValue in
                guard let d = newValue,
                      let nearest = series.bars.min(by: {
                          abs($0.bucket.start.timeIntervalSince(d))
                              < abs($1.bucket.start.timeIntervalSince(d))
                      }) else { selectedBucket = nil; return }
                selectedBucket = nearest.bucket.start
            }))
        .chartPlotStyle {
            $0.background(Color.black.opacity(0.2))
                // No trailing padding here. There used to be one: the
                // "your 90d"/"typical" RuleMark carried a
                // `position: .trailing, alignment: .leading` annotation that
                // extended rightward past the plot's own bounds, and Swift
                // Charts does not shrink a plot to fit an overflowing
                // annotation on its own — so without a reserved margin that
                // label ran past the plot and was hard-clipped by
                // `.cardStyle()`'s `.clipShape`. That annotation now lives in
                // `referenceLegend` in the header instead, so nothing draws
                // past the plot's trailing edge any more and the bars can use
                // the full width. If a future change reintroduces an
                // in-plot trailing annotation, it will need this margin back.
                //
                // Safety net: even with bars anchored inside yDomain (see
                // barAnchor), nothing should be able to draw outside the plot
                // area and over the footer text below it. Scoped to the
                // plot's own background/border layer rather than the whole
                // chart, so it does not touch the top-of-bar value
                // annotations, which Charts renders outside this layer by
                // design.
                .clipShape(Rectangle())
        }
    }

    /// One bar per bucket: a day for W and M, a calendar month for 6M. Must
    /// match whatever granularity `TrackSeriesBuilder.bars` actually produced
    /// for this period, or Charts spaces/widths the bars against the wrong
    /// unit and they no longer line up with their bucket.
    private var xUnit: Calendar.Component {
        switch period {
        case .week, .month: return .day
        case .sixMonth:     return .month
        }
    }

    /// A month packs ~30 bars into the width W gives 7, so its bars take up
    /// more of their band than W's and 6M's do — at 0.6 they'd be hairlines
    /// with more gap than bar between them.
    private var barWidth: MarkDimension { period == .month ? .ratio(0.82) : .ratio(0.6) }

    /// A 2pt radius on a ~7pt-wide monthly bar rounds most of the bar away;
    /// W's and 6M's are wide enough to carry it.
    private var cornerRadius: CGFloat { period == .month ? 1 : 2 }

    /// Whether each bar prints its own value on top. False for the month —
    /// see this view's doc comment for why, and for what carries the numbers
    /// there instead.
    private var showsBarValues: Bool { period != .month }

    private func barColor(_ bar: TrackBar, value: Double) -> Color {
        if selectedBucket == bar.bucket.start { return spec.color }
        // Days that beat the reference line stay bright; the rest recede so
        // the line reads at a glance. With no reference line at all (no prior
        // period to compare against yet) there's nothing to fade against, so
        // every bar reads at full strength rather than all being dimmed.
        guard let ref = series.referenceLines.first?.value else { return spec.color.opacity(0.9) }
        let better = spec.def.direction.benefit(value) > spec.def.direction.benefit(ref)
        return spec.color.opacity(better ? 0.9 : 0.45)
    }

    /// Where bars are anchored, vertically. Always the visible domain's
    /// floor: for zero-based metrics that floor is 0 (so this matches the
    /// old zero-anchored look exactly); for index metrics it's the domain's
    /// actual lower bound, which keeps the bar inside the plotted band
    /// instead of running to zero and off the bottom of the chart.
    private var barAnchor: Double { yDomain.lowerBound }

    private var yDomain: ClosedRange<Double> {
        let refValues = series.referenceLines.map(\.value)
        let values = series.bars.compactMap(\.value) + refValues
        let hi = values.max() ?? 1
        let lo = values.min() ?? 0

        if spec.zeroBased {
            // Headroom so the value annotations are not clipped.
            return 0...(hi * 1.25)
        }
        // Index metrics hover in a narrow band; anchoring on the observed
        // spread keeps the differences visible instead of flattening them.
        // Falls back to the page's own average (rather than a reference
        // line) when there is no prior period to compare against yet, so the
        // domain still has something sensible to be proportional to.
        let anchor = refValues.first ?? series.average ?? 0
        let spread = max(hi - lo, abs(anchor) * 0.1)
        return (lo - spread * 0.3)...(hi + spread * 0.6)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(series.summary)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.text.opacity(0.85))
            Text(spec.trendWhy)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
