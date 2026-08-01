import Charts
import SwiftUI

/// Heart-rate demand and vagal withdrawal across a session, on one normalised
/// axis — and the gap between them is the reading.
///
/// Both curves rise during work, so they are directly comparable. Where the
/// vagal curve sits *above* the heart-rate curve, more vagal tone was spent
/// than that heart rate accounts for. The filled area between them is the
/// session's autonomic cost: the same quantity the Suppression card reports as
/// a slope, shown here as a time series.
///
/// Deliberately a single 0–100 axis. Two y-scales would let the two curves be
/// slid past each other arbitrarily, which would make the gap — the whole
/// point of the chart — meaningless.
struct SessionTimelineChart: View {
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let restingHR: Float
    let ceiling:   Float
    /// Pre-session DC, the reference for "how much vagal tone is withdrawn".
    let dcPre:     Float?

    /// Built once per render. Previously a computed property that
    /// `hasVagalTrace` re-evaluated, bucketing up to 10,000 samples twice on
    /// every pass.
    private var samples: [TimelinePoint] {
        SessionTimelineSeries.build(
            samples: points.map { (date: $0.timestamp, hr: $0.meanBPM, dc: $0.dc) },
            startedAt: startedAt, endedAt: endedAt,
            restingHR: restingHR, ceiling: ceiling, dcPre: dcPre)
    }

    var body: some View {
        let samples = self.samples
        let hasVagalTrace = samples.contains { $0.withdrawn != nil }
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                // The cost band, drawn first so the lines sit on top of it.
                if hasVagalTrace {
                    ForEach(samples) { s in
                        if let w = s.withdrawn {
                            // Keyed by segment for the same reason as the
                            // lines: without it the fill sweeps across a
                            // dropout as one continuous wedge, which is the
                            // same false claim the broken stroke avoids.
                            AreaMark(x: .value("Time", s.date),
                                     yStart: .value("HR", s.hrr),
                                     yEnd: .value("Vagal", w),
                                     series: .value("Series", "cost-\(s.segment)"))
                                .foregroundStyle(Theme.hrv.opacity(0.16))
                        }
                    }
                }

                // Optional y-values: a nil at a coverage gap breaks the stroke
                // instead of drawing a straight, confident line across minutes
                // the strap never recorded.
                ForEach(samples) { s in
                    LineMark(x: .value("Time", s.date),
                             y: .value("% used", s.hrr),
                             series: .value("Series", "hr-\(s.segment)"))
                        .foregroundStyle(Theme.rsa)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }

                ForEach(samples) { s in
                    if let w = s.withdrawn {
                        LineMark(x: .value("Time", s.date),
                                 y: .value("% used", w),
                                 series: .value("Series", "vagal-\(s.segment)"))
                            .foregroundStyle(Theme.hrv)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(height: 150)

            // Two series, so a legend is not optional.
            HStack(spacing: 14) {
                legendItem(Theme.rsa, "effort")
                if hasVagalTrace {
                    legendItem(Theme.hrv, "vagal tone spent")
                    legendItem(Theme.hrv.opacity(0.3), "the gap = what it cost", block: true)
                }
            }
            explainer
        }
    }

    /// "autonomic cost" named a quantity without explaining it. The gap
    /// between the two lines is the whole reading, so the chart says so.
    private var explainer: some View {
        Text("Both lines rise as you work. Where the blue sits above the orange, you were spending more vagal tone than the effort alone accounts for — that gap is the cost.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func legendItem(_ color: Color, _ label: String,
                            block: Bool = false) -> some View {
        HStack(spacing: 5) {
            // A swatch has to match the mark it stands for: a hairline for a
            // line series, a filled block for an area.
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: block ? 9 : 3)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }
}
