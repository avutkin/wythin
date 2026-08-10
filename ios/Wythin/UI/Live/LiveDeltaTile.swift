import SwiftUI

/// One Live-grid tile, percent-first: the hero number is the day's average
/// versus the last seven recorded days; the live reading and both averages
/// shrink to a footnote. Color carries judgement (benefit direction), the
/// arrow carries the raw direction of the number, and intensity carries how
/// unusual the shift is for this metric (z-scaled, so tiles only get loud
/// when the day is genuinely off this person's norm).
struct LiveDeltaTile: View {
    let label:     String
    let techLabel: String
    let unit:      String

    /// Formatted current reading — live tick on today, day average on past
    /// days. Shown as the hero only when there is no comparison to lead with.
    let valueText: String
    /// Formatted day average (today only; past days fold it into `valueText`).
    let todayText: String?
    /// Formatted reference-week mean.
    let refText:   String?

    let delta: LiveDayDelta?
    /// Live reading vs today's average, % — the quiet corner chip.
    let nowPercent: Float?
    let nowBeneficial: Bool?

    private var tone: Color {
        guard let d = delta, !d.neutral else { return Theme.dim }
        return d.beneficial ? Theme.accent : Theme.warn
    }

    private var heroText: String {
        guard let d = delta else { return valueText }
        let arrow = d.neutral ? "≈" : (d.percent >= 0 ? "▲" : "▼")
        return String(format: "%@ %+.0f%%", arrow, d.percent)
    }

    private var heroColor: Color {
        guard let d = delta else { return Theme.text }
        return d.neutral ? Theme.dim.opacity(0.75) : tone.opacity(Double(max(0.45, d.intensity)))
    }

    /// Chip stays gray inside ±5% — moment-to-moment wobble is not news.
    private var chipColor: Color {
        guard let p = nowPercent, abs(p) >= 5, let good = nowBeneficial else {
            return Theme.dim
        }
        return (good ? Theme.accent : Theme.warn).opacity(0.75)
    }

    private var washOpacity: Double {
        guard let d = delta, !d.neutral else { return 0 }
        return Double(d.intensity)
    }

    var body: some View {
        // A tile is ~90 pt of content on a phone, so every row must survive
        // that width: the name gets the full first line (scaling down before
        // truncating), the unit rides with the tech label instead of being
        // repeated per value, and the absolutes split across two short
        // footer lines instead of one long one.
        VStack(alignment: .leading, spacing: 0) {
            // Two lines reserved so "Conscious Breathing" wraps instead of
            // shrinking toward invisibility; the fixed height keeps the nine
            // tiles' heroes on the same optical row.
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(minHeight: 27, alignment: .topLeading)
            if !techLabel.isEmpty || !unit.isEmpty {
                Text(techLabel + (unit.isEmpty ? "" : " · \(unit)"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            Text(heroText)
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .foregroundStyle(heroColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minHeight: 30)
                .padding(.top, 8)

            Spacer(minLength: 6)

            // One short line per value — each fits a phone-width column at
            // full size, so no number ever scales below readable.
            if todayText != nil {
                footLine {
                    Text("now ").foregroundStyle(Theme.dim.opacity(0.6))
                    + Text(valueText).foregroundStyle(Theme.dim)
                    + Text(nowPercent.map { String(format: "  %+.0f%%", $0) } ?? "")
                        .foregroundStyle(chipColor)
                }
            }
            footLine {
                Text((todayText != nil ? "today " : "avg ")).foregroundStyle(Theme.dim.opacity(0.6))
                + Text(todayText ?? valueText).foregroundStyle(Theme.dim)
            }
            if let r = refText {
                footLine {
                    Text("7d ").foregroundStyle(Theme.dim.opacity(0.6))
                    + Text(r).foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .padding(12)
        .background(
            ZStack {
                Theme.surface
                LinearGradient(
                    colors: [tone.opacity(0.16 * washOpacity), tone.opacity(0.03 * washOpacity)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tone.opacity(0.28 * washOpacity), lineWidth: 1)
        )
    }

    /// One footer line: concatenated `Text`s so mixed colors still scale and
    /// truncate as a single run instead of wrapping mid-line.
    private func footLine(_ content: () -> Text) -> some View {
        content()
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .padding(.top, 2)
    }
}
