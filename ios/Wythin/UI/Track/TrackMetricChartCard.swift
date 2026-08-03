import SwiftUI
import Charts

/// One metric's bar chart for one page: header average, benefit-signed delta,
/// bars with their values printed on top, and the personal reference line.
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
                    Text(spec.def.techLabel)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
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

    /// A small legend for the chart's dashed reference line — living in the
    /// header rather than as an in-plot annotation. The line used to carry
    /// its own label anchored at the plot's trailing edge; that required the
    /// plot to reserve a margin for it, which is exactly the dead space at
    /// the right of the bars the card exists to fix. Moving the label up
    /// here instead lets the bars run the full width of the plot.
    @ViewBuilder
    private var referenceLegend: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(Theme.dim.opacity(0.6))
                .frame(width: 9, height: 1)
            Text(series.referenceIsPersonal ? "your 90d" : "typical")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.8))
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            // Labelled by `referenceLegend` in the header, not here — see that
            // property's doc for why the label moved off the plot.
            RuleMark(y: .value("reference", series.reference))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Theme.dim.opacity(0.6))

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
                        width:  .ratio(0.6)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(barColor(bar, value: v))
                    .annotation(position: .top, spacing: 2) {
                        Text(spec.def.format(v))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
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
        }
        .frame(height: 132)
        .chartYScale(domain: yDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            // Every period's bars get an axis label: W and 6M always did
            // (≤7 bars), and now M does too, since its bars are calendar
            // weeks (≤6 of them, same as 6M) rather than ~30 days. That
            // used to need a "label only the extremes" thinning pass to
            // stay legible — moot now that there's nothing to thin.
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

    /// One bar per bucket: a day for W, a calendar week for M, a calendar
    /// month for 6M. Must match whatever granularity `TrackSeriesBuilder.bars`
    /// actually produced for this period, or Charts spaces/widths the bars
    /// against the wrong unit and they no longer line up with their bucket.
    private var xUnit: Calendar.Component {
        switch period {
        case .week:     return .day
        case .month:    return .weekOfYear
        case .sixMonth: return .month
        }
    }

    private func barColor(_ bar: TrackBar, value: Double) -> Color {
        if selectedBucket == bar.bucket.start { return spec.color }
        // Days that beat the reference stay bright; the rest recede so the
        // line reads at a glance.
        let better = spec.def.direction.benefit(value) > spec.def.direction.benefit(series.reference)
        return spec.color.opacity(better ? 0.9 : 0.45)
    }

    /// Where bars are anchored, vertically. Always the visible domain's
    /// floor: for zero-based metrics that floor is 0 (so this matches the
    /// old zero-anchored look exactly); for index metrics it's the domain's
    /// actual lower bound, which keeps the bar inside the plotted band
    /// instead of running to zero and off the bottom of the chart.
    private var barAnchor: Double { yDomain.lowerBound }

    private var yDomain: ClosedRange<Double> {
        let values = series.bars.compactMap(\.value) + [series.reference]
        let hi = values.max() ?? 1
        let lo = values.min() ?? 0

        if spec.zeroBased {
            // Headroom so the value annotations are not clipped.
            return 0...(hi * 1.25)
        }
        // Index metrics hover in a narrow band; anchoring on the observed
        // spread keeps the differences visible instead of flattening them.
        let spread = max(hi - lo, abs(series.reference) * 0.1)
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
