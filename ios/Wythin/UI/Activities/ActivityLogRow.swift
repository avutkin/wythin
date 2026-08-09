import SwiftUI
import SwiftData

// MARK: - ActivityLogRow

struct ActivityLogRow: View {
    let entry: ActivityLog

    @State private var showCoverage = false

    // 3×3 grid of the nine metrics grouped under the row header.
    private let metricCols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private var timeStr: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let start = fmt.string(from: entry.startedAt)
        if let end = entry.endedAt {
            return "\(start)–\(fmt.string(from: end))"
        }
        return start
    }

    private func deltaColor(_ delta: Double) -> Color {
        if delta > 2  { return Theme.accent }
        if delta < -2 { return Theme.warn }
        return Theme.dim
    }

    /// Spells out that the headline is a mean of the tiles, over how many of
    /// them, and what kept any of the nine out.
    private func coverageExplanation(_ coverage: ImpactCoverage) -> String {
        var lines = ["The average change across \(coverage.counted) of the \(coverage.total) metrics below, comparing the session against the five minutes before it."]
        if !coverage.missing.isEmpty {
            lines.append("")
            lines.append(coverage.missing.count == 1
                         ? "One metric couldn't be included:"
                         : "\(coverage.missing.count) metrics couldn't be included:")
            for gap in coverage.missing {
                lines.append("\n\(gap.label) — \(gap.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + name + time
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
                            Text("LIVE").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.warn)
                        } else {
                            Text(entry.durationString).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    }
                }

                Spacer()

                if let delta = entry.impactDeltaPct {
                    let coverage = entry.impactCoverage
                    Button { showCoverage = true } label: {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%+.0f%%", delta))
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(deltaColor(delta))
                            // The denominator, always. This number is the mean of
                            // the tiles below, and which tiles it could use varies
                            // session to session.
                            HStack(spacing: 3) {
                                Text(coverage.summary)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(coverage.isComplete ? Theme.dim : Theme.warn.opacity(0.9))
                                if !coverage.isComplete {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Theme.warn.opacity(0.9))
                                }
                            }
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            Text(ActivityImpact.caption(for: delta))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .alert("How this number is made", isPresented: $showCoverage) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text(coverageExplanation(coverage))
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim.opacity(0.4))
            }

            // All nine metrics — during value + benefit-signed difference.
            LazyVGrid(columns: metricCols, spacing: 6) {
                ForEach(activityMetricDefs) { def in
                    LogMetricCell(def: def, entry: entry)
                }
            }
        }
        .padding(.vertical, 7)
    }
}

/// One metric mini-cell in a log row: consumer-friendly name, the % change
/// from the before-average to the during-average (the hero number), and the
/// during value shown small underneath. The % is colored green when the
/// change is a benefit for that metric, red when it isn't.
struct LogMetricCell: View {
    let def:   ActivityMetricDef
    let entry: ActivityLog

    private var during: Double? { entry[keyPath: def.duringKey].map(Double.init) }
    private var before: Double? { entry[keyPath: def.beforeKey].map(Double.init) }

    /// Benefit-signed change from the before-average to the during-average, so
    /// this cell's number is directly comparable to the row badge above it —
    /// the badge is the mean of these. A falling pulse reads +9%, which is why
    /// the absolute during-value stays printed underneath.
    private var pctChange: Double? {
        def.benefitDelta(current: during, base: before)
    }

    private var deltaColor: Color {
        guard let p = pctChange else { return Theme.dim.opacity(0.4) }
        if abs(p) < 0.05 { return Theme.dim }
        return p > 0 ? Theme.accent : Theme.warn
    }

    private var deltaText: String {
        guard let p = pctChange else { return "—" }
        return (p >= 0 ? "+" : "−") + String(format: "%.0f%%", abs(p))
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(def.label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 22, alignment: .bottom)
            Text(deltaText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(deltaColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(def.format(during))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Theme.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
