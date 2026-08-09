import SwiftUI
import SwiftData

// MARK: - ActivityLogRow

struct ActivityLogRow: View {
    let entry: ActivityLog

    @State private var showCoverage = false

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
                                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                .foregroundStyle(deltaColor(delta))
                            // Verdict first, then the qualifier — the plain-English
                            // read is what the number is for; the denominator is
                            // what keeps it honest.
                            Text(ActivityImpact.caption(for: delta))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            HStack(spacing: 3) {
                                Text("\(coverage.counted) of \(coverage.total) metrics")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(coverage.isComplete ? Theme.dim.opacity(0.7)
                                                                         : Theme.warn.opacity(0.9))
                                Image(systemName: "info.circle")
                                    .font(.system(size: 7))
                                    .foregroundStyle(coverage.isComplete ? Theme.dim.opacity(0.7)
                                                                         : Theme.warn.opacity(0.9))
                            }
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

            MetricRail(entry: entry)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Metric rail

/// The nine metrics as bars diverging from one shared zero line.
///
/// The previous grid printed a percentage *and* an absolute value per metric,
/// with no common axis — eighteen numbers, and comparing any two of them was an
/// act of arithmetic. Here length carries the magnitude and side carries the
/// direction, so the session has a readable shape before a single number is
/// read. Absolute values are gone; they live in the detail view this row opens.
///
/// Metric order is fixed, never sorted by size: a row that moves between
/// sessions can't be found by muscle memory, and these cards are meant to be
/// compared to each other.
private struct MetricRail: View {
    let entry: ActivityLog

    /// The scale runs to ±50%. Beyond that a bar is capped and marked, which
    /// also flags the readings worth least trust — `benefitDelta` clamps at
    /// ±100, so anything out there is a lower bound rather than a measurement.
    private let fullScale: Double = 50

    private let labelWidth: CGFloat = 104
    private let valueWidth: CGFloat = 46
    private let rowHeight:  CGFloat = 21

    var body: some View {
        VStack(spacing: 0) {
            scaleCaps
            // No spacing between rows, so each row's rail segment joins the next
            // into one continuous spine.
            ForEach(activityMetricDefs) { def in
                row(def)
            }
        }
    }

    /// The scale, stated once. Without it a long bar is a mood rather than a
    /// quantity.
    private var scaleCaps: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: labelWidth)
            HStack {
                Text("−\(Int(fullScale))%")
                Spacer()
                Text("0")
                Spacer()
                Text("+\(Int(fullScale))%")
            }
            .font(.system(size: 7, design: .monospaced))
            .foregroundStyle(Theme.dim.opacity(0.55))
            Spacer().frame(width: valueWidth)
        }
        .padding(.bottom, 3)
    }

    private func row(_ def: ActivityMetricDef) -> some View {
        let during = entry[keyPath: def.duringKey].map(Double.init)
        let before = entry[keyPath: def.beforeKey].map(Double.init)
        let pct    = def.benefitDelta(current: during, base: before)

        return HStack(spacing: 8) {
            Text(def.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(pct == nil ? Theme.dim.opacity(0.5) : Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: labelWidth, alignment: .leading)

            track(pct, gap: pct == nil ? gapTag(during: during, before: before) : nil)

            Text(pct.map { ($0 >= 0 ? "+" : "−") + String(format: "%.0f%%", abs($0)) } ?? "")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(pct))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .frame(height: rowHeight)
    }

    private func track(_ pct: Double?, gap: String?) -> some View {
        GeometryReader { geo in
            let half     = geo.size.width / 2
            let magnitude = min(abs(pct ?? 0), fullScale) / fullScale
            let length   = half * magnitude
            let positive = (pct ?? 0) >= 0

            ZStack {
                // The spine. Drawn full-height so consecutive rows join up.
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)

                if let gap {
                    Text(gap)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, half + 6)
                } else if pct != nil {
                    Capsule()
                        .fill(color(pct))
                        .frame(width: max(length, 2), height: 7)
                        .offset(x: positive ? length / 2 : -length / 2)

                    if abs(pct ?? 0) > fullScale {
                        Image(systemName: positive ? "chevron.right" : "chevron.left")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(color(pct))
                            .offset(x: positive ? half + 5 : -(half + 5))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity)
    }

    /// Why this metric has no bar, in the two words there is room for. The full
    /// explanation is behind the header badge.
    private func gapTag(during: Double?, before: Double?) -> String {
        switch (before, during) {
        case (nil, nil): return "no data"
        case (nil, _):   return "no baseline"
        case (_, nil):   return "no reading"
        default:         return "zero baseline"
        }
    }

    private func color(_ pct: Double?) -> Color {
        guard let p = pct else { return Theme.dim.opacity(0.4) }
        if abs(p) < 2 { return Theme.dim }
        return p > 0 ? Theme.accent : Theme.warn
    }
}
