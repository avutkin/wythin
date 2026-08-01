import Charts
import SwiftUI

/// Vagal tone against work — the cost relationship, plotted.
///
/// Each dot is a moment of the session: how hard you were working (x) and how
/// much vagal tone was left (y). The line through them is the session's cost
/// rate. **A steeper downward line means you spent more vagal tone to do the
/// same work.** That slope is the number on the card.
///
/// Suppression plots this against heart rate; Efficiency plots the identical
/// relationship against physical movement. The substitution of one x-axis for
/// the other is the entire difference between the two axes, which is why they
/// share a chart.
struct CostScatterChart: View {
    let points:    [(x: Double, y: Double)]
    let xLabel:    String
    let tint:      Color
    /// Drawn faintly behind, when there is enough history to have one.
    var baselineSlope: Double? = nil

    private struct Dot: Identifiable { let id: Int; let x: Double; let y: Double }

    private var dots: [Dot] {
        points.enumerated().map { Dot(id: $0.offset, x: $0.element.x, y: $0.element.y) }
    }

    /// Ordinary least squares through the plotted dots, so the drawn line is
    /// the same fit the score was computed from rather than a second opinion.
    private var fit: (slope: Double, intercept: Double)? {
        guard points.count >= 4 else { return nil }
        let n  = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n
        let my = points.reduce(0) { $0 + $1.y } / n
        var num = 0.0, den = 0.0
        for p in points {
            num += (p.x - mx) * (p.y - my)
            den += (p.x - mx) * (p.x - mx)
        }
        guard den > 0 else { return nil }
        let slope = num / den
        return (slope, my - slope * mx)
    }

    private var xRange: ClosedRange<Double>? {
        guard let lo = points.map(\.x).min(), let hi = points.map(\.x).max(), hi > lo else { return nil }
        return lo...hi
    }

    var body: some View {
        if let range = xRange, let fit {
            VStack(alignment: .leading, spacing: 7) {
                Chart {
                    ForEach(dots) { d in
                        PointMark(x: .value(xLabel, d.x), y: .value("Vagal tone", d.y))
                            .foregroundStyle(tint.opacity(0.35))
                            .symbolSize(18)
                    }

                    if let base = baselineSlope {
                        let mid = (range.lowerBound + range.upperBound) / 2
                        let c   = fit.intercept + fit.slope * mid - base * mid
                        ForEach([range.lowerBound, range.upperBound], id: \.self) { x in
                            LineMark(x: .value(xLabel, x),
                                     y: .value("Vagal tone", base * x + c),
                                     series: .value("s", "baseline"))
                                .foregroundStyle(Theme.dim)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }

                    ForEach([range.lowerBound, range.upperBound], id: \.self) { x in
                        LineMark(x: .value(xLabel, x),
                                 y: .value("Vagal tone", fit.intercept + fit.slope * x),
                                 series: .value("s", "session"))
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel()
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                    }
                }
                .frame(height: 116)

                HStack {
                    Text("← \(xLabel) →")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    if baselineSlope != nil {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.dim)
                                .frame(width: 9, height: 2)
                            Text("your usual")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
                Text(fit.slope > 0
                     ? "Each dot is one moment. Vagal tone runs up the side, work runs across. Here the line rises: your vagal tone went up as you worked, which is what a genuinely restorative session looks like."
                     : "Each dot is one moment. Vagal tone runs up the side, work runs across. A steeper fall means more vagal tone spent for the same work.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
