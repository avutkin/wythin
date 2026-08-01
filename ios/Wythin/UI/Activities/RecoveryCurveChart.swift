import Charts
import SwiftUI

/// The whole arc of the vagal brake: where it sat before, how far it was
/// pushed down during, and how far back up it climbed afterwards.
///
/// Showing only the tail hid the thing that gives the tail meaning. The dashed
/// line is your pre-session level, the shaded band is the session itself, and
/// the marker is the moment vagal tone crossed back — or a plain statement that
/// it had not crossed back by the time the recording ends.
struct RecoveryCurveChart: View {
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    /// Pre-session DC — the level being returned to.
    let dcPre:     Float?

    private struct Dot: Identifiable {
        let id: Int
        let minutes: Double     // relative to session end; negative = during
        let dc: Double
    }

    private var dots: [Dot] {
        points
            .filter { $0.dc != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { Dot(id: $0.offset,
                       minutes: $0.element.timestamp.timeIntervalSince(endedAt) / 60,
                       dc: Double($0.element.dc!)) }
    }

    /// Minutes after the end at which vagal tone first came back within 10 % of
    /// where it started, and stayed there for the rest of the record.
    private func minutesToBaseline(_ dots: [Dot], pre: Double) -> Double? {
        let after = dots.filter { $0.minutes >= 0 }
        guard !after.isEmpty else { return nil }
        let target = pre * 0.9
        guard let idx = after.firstIndex(where: { $0.dc >= target }) else { return nil }
        // Must hold, not merely touch — a single noisy sample is not recovery.
        guard after[idx...].allSatisfy({ $0.dc >= target * 0.92 }) else { return nil }
        return after[idx].minutes
    }

    private var sessionStartMinutes: Double {
        startedAt.timeIntervalSince(endedAt) / 60
    }

    var body: some View {
        let d = dots
        if let preF = dcPre, preF > 0, d.count >= 3 {
            let pre = Double(preF)
            let recovered = minutesToBaseline(d, pre: pre)
            let lastMinute = d.map(\.minutes).max() ?? 0

            VStack(alignment: .leading, spacing: 7) {
                Chart {
                    RectangleMark(xStart: .value("s", sessionStartMinutes),
                                  xEnd: .value("e", 0))
                        .foregroundStyle(Theme.warn.opacity(0.07))

                    RuleMark(y: .value("Pre-session", pre))
                        .foregroundStyle(Theme.dim)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("where you started")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    ForEach(d) { p in
                        LineMark(x: .value("Minutes", p.minutes),
                                 y: .value("Vagal brake", p.dc))
                            .foregroundStyle(p.minutes < 0 ? Theme.warn : Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }

                    if let r = recovered {
                        RuleMark(x: .value("Recovered", r))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("back at \(Int(r)) min")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel {
                            if let m = value.as(Double.self) {
                                Text(m < 0 ? "\(Int(m))m" : "+\(Int(m))m")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.border.opacity(0.5)) }
                }
                .frame(height: 128)

                HStack(spacing: 14) {
                    legend(Theme.warn, "during")
                    legend(Theme.accent, "after")
                }

                Text(recovered.map {
                        "Your vagal brake was back within 10% of its starting level \(Int($0)) minutes after you stopped."
                     } ?? "Vagal tone had not returned to its starting level by \(Int(max(lastMinute, 0))) minutes after you stopped — the recording ends before full recovery.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 3)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }
}
