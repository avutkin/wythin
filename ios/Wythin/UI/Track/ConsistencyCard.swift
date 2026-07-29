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
                stats: practiceStats,
                values: summary.buckets.map(\.practiceMinutes),
                color: Theme.accent,
                format: { $0 < 1 ? "" : String(format: "%.0f", $0) })

            row(title: "WEAR",
                stats: String(format: "avg %.1f h/day", summary.avgWearHours),
                values: summary.buckets.map(\.wearHours),
                color: Theme.hrv,
                format: { $0 < 0.5 ? "" : String(format: "%.0f", $0) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .padding(.horizontal)
    }

    private var practiceStats: String {
        let sessions = "\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")"
        let minutes  = String(format: "%.0f min", summary.totalPracticeMinutes)
        let streak   = summary.streak.current > 0 ? "  🔥 \(summary.streak.current)d" : ""
        return "\(sessions)   \(minutes)\(streak)"
    }

    private func row(title: String, stats: String, values: [Double],
                     color: Color, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(stats)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            Chart {
                ForEach(Array(zip(summary.buckets, values)), id: \.0.id) { bucket, value in
                    BarMark(
                        x: .value("Bucket", bucket.bucket.start, unit: xUnit),
                        y: .value(title, value),
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

    private var xUnit: Calendar.Component { period == .sixMonth ? .month : .day }

    /// Thirty labels do not fit across a phone; the month view drops them.
    private var showLabels: Bool { period != .month }

    private func showAxisLabel(_ d: Date) -> Bool {
        guard period == .month else { return true }
        return Calendar.current.component(.day, from: d) % 5 == 1
    }
}
