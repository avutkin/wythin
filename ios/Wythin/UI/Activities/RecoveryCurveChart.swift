import Charts
import SwiftUI

/// The whole arc of the vagal brake across the three windows the app measures:
/// the five minutes before, the session itself, and the ten minutes after.
///
/// The x-axis is anchored to the session, not to the clock: 0 is when you
/// started, so the session occupies 0 → duration and recovery runs on from
/// there. Signed minutes counted back from the end made "−40m" mean a point
/// before the session began, which read as an error even when it was not.
struct RecoveryCurveChart: View {
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    /// Pre-session DC — the level being returned to.
    let dcPre:     Float?

    /// Which window a sample belongs to. Each is its own series, because a
    /// per-point foregroundStyle on one series does not repaint the segments —
    /// the whole line took a single colour, so "after" was drawn as "during".
    private enum Phase: String { case before, during, after }

    private struct Dot: Identifiable {
        let id: Int
        let minutes: Double      // from session start
        let dc: Double
        let phase: Phase
    }

    private var sessionMinutes: Double { endedAt.timeIntervalSince(startedAt) / 60 }

    private var dots: [Dot] {
        points
            .filter { $0.dc != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { i, p in
                let m = p.timestamp.timeIntervalSince(startedAt) / 60
                let phase: Phase = m < 0 ? .before : (m <= sessionMinutes ? .during : .after)
                return Dot(id: i, minutes: m, dc: Double(p.dc!), phase: phase)
            }
    }

    /// Minutes after the end at which vagal tone first came back within 10 % of
    /// where it started, and held there.
    private func recoveredAt(_ dots: [Dot], pre: Double) -> Double? {
        let after = dots.filter { $0.phase == .after }
        guard !after.isEmpty else { return nil }
        let target = pre * 0.9
        guard let idx = after.firstIndex(where: { $0.dc >= target }) else { return nil }
        guard after[idx...].allSatisfy({ $0.dc >= target * 0.92 }) else { return nil }
        return after[idx].minutes - sessionMinutes
    }

    var body: some View {
        let d = dots
        if let preF = dcPre, preF > 0, d.count >= 3 {
            let pre = Double(preF)
            let recovered = recoveredAt(d, pre: pre)
            let lastAfter = (d.filter { $0.phase == .after }.map(\.minutes).max() ?? sessionMinutes)
                - sessionMinutes

            VStack(alignment: .leading, spacing: 7) {
                Chart {
                    RectangleMark(xStart: .value("s", 0), xEnd: .value("e", sessionMinutes))
                        .foregroundStyle(Theme.warn.opacity(0.07))

                    RuleMark(y: .value("Halfway", pre * RecoveryTiming.targetFraction))
                        .foregroundStyle(Theme.accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .bottom, alignment: .leading) {
                            Text("halfway back")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.accent.opacity(0.8))
                        }

                    RuleMark(y: .value("Resting", pre))
                        .foregroundStyle(Theme.dim)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("your resting level")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    ForEach(d) { p in
                        LineMark(x: .value("Minutes", p.minutes),
                                 y: .value("Vagal brake", p.dc),
                                 series: .value("Phase", p.phase.rawValue))
                            .foregroundStyle(color(p.phase))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }

                    if let r = recovered {
                        RuleMark(x: .value("Recovered", sessionMinutes + r))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [0, sessionMinutes, sessionMinutes + 10]) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel {
                            if let m = value.as(Double.self) {
                                Text(m <= 0 ? "start"
                                     : (abs(m - sessionMinutes) < 0.5 ? "end" : "+10m"))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v / pre * 100))%")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                .frame(height: 132)

                HStack(spacing: 14) {
                    legend(Theme.breathe, "before")
                    legend(Theme.warn, "during")
                    legend(Theme.accent, "after")
                }

                Text(recovered.map {
                        "Back within 10% of your resting level \(Int($0)) minutes after you stopped."
                     } ?? (lastAfter >= 1
                        ? "Still below your resting level \(Int(lastAfter)) minutes after you stopped."
                        : "The recording ends too soon after this session to see recovery."))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ p: Phase) -> Color {
        switch p {
        case .before: return Theme.breathe
        case .during: return Theme.warn
        case .after:  return Theme.accent
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
