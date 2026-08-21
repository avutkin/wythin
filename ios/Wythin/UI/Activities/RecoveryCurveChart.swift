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

    /// What this curve is a curve OF.
    ///
    /// One component rather than two near-identical ones, because the arc is
    /// the same question asked of two signals that answer it at different
    /// speeds — and the gap between those speeds is the finding the recovery
    /// section exists to show.
    enum Channel {
        /// Deceleration Capacity, the vagal brake. Recovery is a climb.
        case vagalBrake
        /// Heart rate. Recovery is a fall.
        case heartRate

        var recoversUpward: Bool { self == .vagalBrake }

        var seriesName: String {
            switch self {
            case .vagalBrake: return "Vagal brake (DC)"
            case .heartRate:  return "Heart rate"
            }
        }

        var restingLabel: String {
            switch self {
            case .vagalBrake: return "your resting level"
            case .heartRate:  return "your resting heart rate"
            }
        }

        /// What the caption underneath calls the thing that came back.
        var subject: String {
            switch self {
            case .vagalBrake: return "your vagal brake"
            case .heartRate:  return "your heart rate"
            }
        }
    }

    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let channel:   Channel
    /// The outcome the score was computed from.
    ///
    /// Passed in rather than re-derived here. This view used to run its own
    /// crossing rule over its own ten-minute slice of samples while the stored
    /// number came from a four-hour fetch, so the caption could read "Halfway
    /// back 0 minutes after you stopped" directly beneath a headline of
    /// ">34 min · not halfway yet". One rule, one window, one answer.
    let outcome:   RecoveryTiming.Outcome

    /// Pre-session level — what is being returned to.
    let dcPre:     Float?
    /// Where it bottomed out (DC) or peaked (heart rate) during the session.
    ///
    /// **Required, and its absence was a bug.** The dashed "halfway back" line
    /// used to be drawn at `pre * targetFraction` — half of the RESTING level —
    /// while `RecoveryTiming` scores against `trough + (pre - trough) / 2`,
    /// halfway out of the hole. `RecoveryTiming`'s own doc comment calls
    /// half-of-resting "the first attempt and is wrong"; the chart went on
    /// drawing it. The drawn line sits lower than the scored one, so a session
    /// could clear the line on screen while failing the bar being scored —
    /// which is exactly what a reader would call the number broken.
    let extreme:   Float?

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

    private func measure(_ p: MetricsHistoryPoint) -> Float? {
        switch channel {
        case .vagalBrake: return p.dc
        case .heartRate:  return p.meanBPM
        }
    }

    private var dots: [Dot] {
        points
            .filter { measure($0) != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { i, p in
                let m = p.timestamp.timeIntervalSince(startedAt) / 60
                let phase: Phase = m < 0 ? .before : (m <= sessionMinutes ? .during : .after)
                return Dot(id: i, minutes: m, dc: Double(measure(p)!), phase: phase)
            }
    }

    private var direction: RecoveryTiming.Direction {
        channel.recoversUpward ? .upward : .downward
    }

    /// The bar being climbed to (or fallen back to) — the SAME one the score
    /// uses, from the same function, so the line on the chart and the number
    /// beside it cannot disagree.
    private func targetLevel(pre: Double) -> Double? {
        guard let extreme = extreme.map(Double.init) else { return nil }
        return direction.target(pre: pre, extreme: extreme)
    }

    /// Each phase is its own series so the colours repaint per segment — but a
    /// series that merely starts where the last one ended leaves a gap at every
    /// boundary, which is the break visible where blue meets red and red meets
    /// green. Each segment therefore opens with the previous segment's final
    /// sample: the line is continuous, and the colour still changes on the
    /// boundary rather than across a hole in it.
    private func joined(_ d: [Dot]) -> [Dot] {
        var out: [Dot] = []
        var nextID = d.count
        for (i, dot) in d.enumerated() {
            if i > 0, d[i - 1].phase != dot.phase {
                out.append(Dot(id: nextID, minutes: d[i - 1].minutes,
                               dc: d[i - 1].dc, phase: dot.phase))
                nextID += 1
            }
            out.append(dot)
        }
        return out
    }

    var body: some View {
        let d = dots
        if let preF = dcPre, preF > 0, d.count >= 3 {
            let pre = Double(preF)
            let bar = targetLevel(pre: pre)
            let recovered: Double? = {
                if case let .reached(minutes) = outcome { return minutes }
                return nil
            }()
            let lastAfter = (d.filter { $0.phase == .after }.map(\.minutes).max() ?? sessionMinutes)
                - sessionMinutes

            VStack(alignment: .leading, spacing: 7) {
                Chart {
                    RectangleMark(xStart: .value("s", 0), xEnd: .value("e", sessionMinutes))
                        .foregroundStyle(Theme.warn.opacity(0.07))

                    if let bar {
                        RuleMark(y: .value("Halfway", bar))
                            .foregroundStyle(Theme.accent.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .bottom, alignment: .trailing) {
                                Text("halfway back \u{2014} the bar being scored")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.accent.opacity(0.8))
                            }
                    }

                    RuleMark(y: .value("Resting", pre))
                        .foregroundStyle(Theme.dim)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(channel.restingLabel)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }

                    ForEach(joined(d)) { p in
                        LineMark(x: .value("Minutes", p.minutes),
                                 y: .value(channel.seriesName, p.dc),
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
                    // The last mark is where the recording actually ends, not a
                    // fixed "+10m" printed over an hour of trace.
                    AxisMarks(values: [0, sessionMinutes, sessionMinutes + max(lastAfter, 1)]) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel {
                            if let m = value.as(Double.self) {
                                Text(m <= 0 ? "start"
                                     : (abs(m - sessionMinutes) < 0.5 ? "end"
                                        : "+\(Int(lastAfter.rounded()))m"))
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

                // Says the same thing the score says. This line used to
                // announce "back within 10% of your resting level" — a third
                // definition of recovered, on a screen that already had two,
                // and the reason the caption could contradict the headline.
                Text(RecoveryTiming.summary(outcome, subject: channel.subject))
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
