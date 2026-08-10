import SwiftUI

// MARK: - ActivityLogRow

/// One restorative session in the Activities list — the approved shape shared
/// with the exercise row: a chip saying which model the session got, a centred
/// score with laurels above half marks, every key metric, and a button into
/// the full session.
///
/// Each metric shows two percentages — during and 10 minutes after — because
/// that pair is the least that can still show whether a shift *held*, which is
/// the thing a single delta could not say at all.
struct ActivityLogRow: View {
    let entry: ActivityLog

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let start = fmt.string(from: entry.startedAt)
        if let end = entry.endedAt {
            return "\(start)–\(fmt.string(from: end))"
        }
        return start
    }

    /// The after-window keypath per metric. The shared def table carries
    /// before/during only (Track never needs after), so the pairing lives here
    /// rather than widening a struct nine call sites construct.
    private static let afterKeys: [String: KeyPath<ActivityLog, Float?>] = [
        "Vagal Tone": \.afterDC,          "Adaptive Capacity": \.afterRCMSE,
        "Inner Noise": \.afterPIP,        "Harmony": \.afterDFA1,
        "Stress Balance": \.afterStress,  "Conscious Breathing": \.afterRSA,
        "Calm Power": \.afterVTI,         "Energy Reserve": \.afterRMSSD,
        "Pulse": \.afterHR,
    ]

    struct Reading: Identifiable {
        var id: String { label }
        let label: String
        let durPct: Double?
        let durValue: String
        let aftPct: Double?
        let aftValue: String
    }

    private var readings: [Reading] {
        activityMetricDefs.map { def in
            let before = entry[keyPath: def.beforeKey].map(Double.init)
            let during = entry[keyPath: def.duringKey].map(Double.init)
            let after  = Self.afterKeys[def.label].flatMap { entry[keyPath: $0] }.map(Double.init)
            return Reading(label: def.label,
                           durPct: def.benefitDelta(current: during, base: before),
                           durValue: def.format(during),
                           aftPct: def.benefitDelta(current: after, base: before),
                           aftValue: def.format(after))
        }
    }

    /// Combined during + after, the rule the proposal settled on: the score
    /// rewards both the shift and its holding.
    private var score: Int? {
        let r = readings
        return RestorativeScore.score(during: r.map(\.durPct), after: r.map(\.aftPct))
    }

    private var verdict: String {
        // From the score, not from the raw mean: the score caps each metric's
        // credit so one outlier cannot buy the celebration, and the word must
        // obey the same cap or the card contradicts itself — the seeded fixture
        // read 47, dim, no laurels, captioned "deeply restorative".
        guard let score else { return "recorded" }
        return ActivityImpact.caption(for: Double(score) / 100 * RestorativeScore.fullMarks)
    }

    private var improvedCount: Int {
        readings.filter { ($0.durPct ?? $0.aftPct ?? 0) > 0 }.count
    }

    private var crowned: Bool { (score ?? 0) >= 50 }

    private var chipText: String {
        if let before = entry.beforeHR.map(Double.init),
           let during = entry.duringHR.map(Double.init),
           during - before >= ActivityClass.activatingHRRise {
            return "PULSE ROSE \(Int((during - before).rounded())) BPM"
        }
        return "NO PULSE RISE"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            hero
            grid
            legend
            viewFullSession
        }
        .padding(.vertical, 7)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(entry.activityTypeEnum.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: entry.activityTypeEnum.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(entry.activityTypeEnum.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(timeStr)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    if entry.isActive {
                        Text("LIVE")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.warn)
                    } else {
                        Text(entry.durationString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }

            Spacer()

            // The other half of the exercise row's gold chip: which model this
            // session got. Violet always — the model is restorative by TYPE
            // now — but the text stays factual: a breathwork round that raised
            // the pulse says so rather than wearing a false "no rise".
            Text(chipText)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Theme.hrv)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.hrv.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    /// Same hero as the exercise row: laurels above half marks, the bare
    /// number without ceremony below it. A sub-50 session keeps its score and
    /// loses only the celebration — nothing scolds.
    @ViewBuilder
    private var hero: some View {
        if let score {
            VStack(spacing: 3) {
                HStack(spacing: 10) {
                    if crowned { laurel("laurel.leading") }
                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 52, weight: .light, design: .rounded))
                            .foregroundStyle(crowned ? Theme.text : Theme.dim)
                            .monospacedDigit()
                        Text("SCORE / 100")
                            .font(.system(size: 8, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Theme.dim)
                    }
                    if crowned { laurel("laurel.trailing") }
                }
                Text(verdict)
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(crowned ? Theme.accent : Theme.dim)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func laurel(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 44, weight: .ultraLight))
            .foregroundStyle(Theme.dim.opacity(0.55))
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(readings) { MetricCell(reading: $0) }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Text("DUR — during")
            Text("AFT — 10 min after")
            Text("\(improvedCount)/9 improved")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(Theme.dim)
        .frame(maxWidth: .infinity)
    }

    private var viewFullSession: some View {
        HStack(spacing: 7) {
            Text("VIEW FULL SESSION")
                .font(.system(size: 11, design: .monospaced))
                .tracking(1.2)
            Image(systemName: "chevron.right").font(.system(size: 9))
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent.opacity(0.32), lineWidth: 0.5))
    }
}

// MARK: - MetricCell

/// One metric: name in white, then the DUR/AFT pair — percentage leading, the
/// absolute value beneath it at 9pt, the phase label beneath that. The change
/// is what gets read, so it is the largest thing in the cell.
private struct MetricCell: View {
    let reading: ActivityLogRow.Reading

    var body: some View {
        VStack(spacing: 5) {
            Text(reading.label)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minHeight: 20)

            HStack(spacing: 5) {
                phase(pct: reading.durPct, value: reading.durValue, tag: "DUR")
                phase(pct: reading.aftPct, value: reading.aftValue, tag: "AFT")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 3)
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func phase(pct: Double?, value: String, tag: String) -> some View {
        VStack(spacing: 1) {
            Text(pctString(pct))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color(pct))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tag)
                .font(.system(size: 7, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity)
    }

    private func pctString(_ pct: Double?) -> String {
        guard let pct else { return "—" }
        let rounded = Int(pct.rounded())
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
    }

    private func color(_ pct: Double?) -> Color {
        guard let pct else { return Theme.dim }
        if pct > 0 { return Theme.accent }
        if pct < 0 { return Theme.warn }
        return Theme.dim
    }
}
