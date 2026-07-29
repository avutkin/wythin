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

    @ViewBuilder
    private var deltaChip: some View {
        if let d = series.deltaPct {
            let better = d >= 0
            Text("\(better ? "▲" : "▼") \(abs(d), specifier: "%.0f")% vs prior \(period.priorNoun)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(better ? Theme.accent : Theme.warn)
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            RuleMark(y: .value("reference", series.reference))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(Theme.dim.opacity(0.6))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(series.referenceIsPersonal ? "your 90d" : "typical")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8))
                }

            ForEach(series.bars) { bar in
                if let v = bar.value {
                    BarMark(
                        x: .value("Bucket", bar.bucket.start, unit: xUnit),
                        y: .value(spec.def.label, v),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(2)
                    .foregroundStyle(barColor(bar, value: v))
                    .annotation(position: .top, spacing: 2) {
                        if labelledBuckets.contains(bar.bucket.start) {
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
                    BarMark(x: .value("Bucket", bar.bucket.start, unit: xUnit),
                           y: .value(spec.def.label, 0))
                        .opacity(0)
                }
            }

            // Month view only: weekly averages as short rules, so ~30 bars stay
            // legible without a number on every one.
            ForEach(series.overlay) { seg in
                RuleMark(
                    xStart: .value("start", seg.start),
                    xEnd:   .value("end", seg.end),
                    y:      .value("weekly", seg.value)
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(spec.color)
                .annotation(position: .top, spacing: 1) {
                    Text(spec.def.format(seg.value))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(spec.color)
                }
            }
        }
        .frame(height: 132)
        .chartYScale(domain: yDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: series.bars.map(\.bucket.start)) { value in
                if let d = value.as(Date.self),
                   let bar = series.bars.first(where: { $0.bucket.start == d }),
                   showAxisLabel(bar) {
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
                // Reserves room for the "your 90d"/"typical" RuleMark
                // annotation, which is anchored at the plot's trailing edge
                // and extends rightward (`position: .trailing, alignment:
                // .leading`). Swift Charts does not shrink the plot to fit an
                // overflowing annotation on its own, so without this the
                // label runs past the plot's layout bounds and is hard-clipped
                // by `.cardStyle()`'s `.clipShape`. Sized to the longer of the
                // two labels ("your 90d", 8 monospaced points) plus a small
                // gap from the plotted bars.
                .padding(.trailing, 42)
        }
    }

    private var xUnit: Calendar.Component { period == .sixMonth ? .month : .day }

    private func barColor(_ bar: TrackBar, value: Double) -> Color {
        if selectedBucket == bar.bucket.start { return spec.color }
        // Days that beat the reference stay bright; the rest recede so the
        // line reads at a glance.
        let better = spec.def.direction.benefit(value) > spec.def.direction.benefit(series.reference)
        return spec.color.opacity(better ? 0.9 : 0.45)
    }

    /// W and 6M label every bar. M would need ~30 numbers across ~350pt, so it
    /// labels only the extremes and the most recent, and leans on the weekly
    /// overlay for the rest.
    private var labelledBuckets: Set<Date> {
        let present = series.bars.filter { $0.value != nil }
        guard period == .month else { return Set(present.map(\.bucket.start)) }
        var keep = Set<Date>()
        if let lo = present.min(by: { $0.value! < $1.value! }) { keep.insert(lo.bucket.start) }
        if let hi = present.max(by: { $0.value! < $1.value! }) { keep.insert(hi.bucket.start) }
        if let last = present.last { keep.insert(last.bucket.start) }
        return keep
    }

    private func showAxisLabel(_ bar: TrackBar) -> Bool {
        guard period == .month else { return true }
        // Every fifth day, so a 31-day axis stays readable.
        if Calendar.current.component(.day, from: bar.bucket.start) % 5 == 1 { return true }
        // `labelledBuckets` always annotates the most recent bar with a
        // value — without a matching axis label under it, that number has
        // no date and the chart can't answer "what did I do most recently."
        // Uses the most recent *present* bar (not series.bars.last) so a
        // future, still-empty day at the end of the current month page
        // doesn't win the slot instead of today.
        return bar.bucket.start == series.bars.filter({ $0.value != nil }).last?.bucket.start
    }

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
            Text(spec.def.why)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension TrackPeriod {
    /// "vs prior week" / "vs prior month" / "vs prior 6 months"
    var priorNoun: String {
        switch self {
        case .week:     return "week"
        case .month:    return "month"
        case .sixMonth: return "6 months"
        }
    }
}
