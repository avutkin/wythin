import Charts
import SwiftUI

/// Vagal tone in the ten minutes after you stopped, against where it started.
///
/// The dashed line is your pre-session level. How close the curve climbs back
/// to it, and how quickly, is the Recovery score — this makes the percentage
/// on the card something you can see rather than something you must trust.
struct RecoveryCurveChart: View {
    let points:    [MetricsHistoryPoint]
    let endedAt:   Date
    /// Pre-session DC — the level being returned to.
    let dcPre:     Float?

    private struct Dot: Identifiable {
        let id: Int
        let minutes: Double
        let dc: Double
    }

    private var after: [Dot] {
        points
            .filter { $0.timestamp >= endedAt && $0.dc != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { Dot(id: $0.offset,
                       minutes: $0.element.timestamp.timeIntervalSince(endedAt) / 60,
                       dc: Double($0.element.dc!)) }
    }

    var body: some View {
        let dots = after
        if let pre = dcPre, pre > 0, dots.count >= 2 {
            VStack(alignment: .leading, spacing: 7) {
                Chart {
                    RuleMark(y: .value("Pre-session", Double(pre)))
                        .foregroundStyle(Theme.dim)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("where you started")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    ForEach(dots) { d in
                        AreaMark(x: .value("Minutes", d.minutes),
                                 y: .value("Vagal tone", d.dc))
                            .foregroundStyle(Theme.accent.opacity(0.14))
                    }
                    ForEach(dots) { d in
                        LineMark(x: .value("Minutes", d.minutes),
                                 y: .value("Vagal tone", d.dc))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                }
                .chartYScale(domain: 0...max(Double(pre) * 1.15, dots.map(\.dc).max() ?? 1))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel {
                            if let m = value.as(Double.self) {
                                Text("\(Int(m))m")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.border.opacity(0.5)) }
                }
                .frame(height: 108)

                Text("Vagal tone climbing back after you stopped. The closer it gets to the dashed line, the more completely you recovered.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
