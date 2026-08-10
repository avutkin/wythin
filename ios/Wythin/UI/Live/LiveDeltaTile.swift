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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !techLabel.isEmpty {
                        Text(techLabel)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let p = nowPercent {
                    HStack(spacing: 3) {
                        Text("now")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                        Text(String(format: "%+.0f%%", p))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(chipColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
                }
            }

            Text(heroText)
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .foregroundStyle(heroColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minHeight: 30)
                .padding(.top, 8)

            Spacer(minLength: 6)

            // now 32.2 · today 37.0 · 7d 41.2 — whatever exists, spread wide.
            HStack(spacing: 0) {
                footValue(todayText != nil ? "now" : "avg", valueText)
                if let t = todayText {
                    Spacer(minLength: 4)
                    footValue("today", t)
                }
                if let r = refText {
                    Spacer(minLength: 4)
                    footValue("7d", r)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
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

    @ViewBuilder
    private func footValue(_ tag: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.6))
            Text(value + (unit.isEmpty ? "" : " \(unit)"))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
