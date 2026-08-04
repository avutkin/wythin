import SwiftUI

/// Today's capacity read: a collapsed one-line strip that expands to the
/// anchor provenance, the recent-mornings sparkline, the narrative, and the
/// local day-load line.
///
/// The score is computed on-device, so this renders offline; only the prose
/// needs the network. The paint is fixed regardless of the reading — a hard
/// morning must read as a low number, not as an alarm — so only the
/// headline's band word carries that information now.
struct DayPotentialStrip: View {
    let store: DayPotentialStore
    @AppStorage("dayPotentialExpanded") private var expanded = false

    private let accent = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            strip
            dots
            baselineBar
            if expanded { expandedBody }
            if store.anchor == nil, (store.streak?.current ?? 0) > 0 { nudge }
        }
    }

    // MARK: Collapsed

    private var strip: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline)
                        .font(Theme.monoLabel)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    ProgressView(value: Double(displayScore ?? 0), total: 100)
                        .tint(accent)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
                Text(store.state.showsScore ? "\(displayScore ?? 0)" : "—")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(store.state.showsScore ? accent : Theme.dim)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var headline: String {
        store.state.headline(band: store.result?.band)
    }

    /// Only the display is floored — `PotentialScore`, the stored result,
    /// and the server all still see a genuine 0.
    private var displayScore: Int? {
        DayPotentialDisplay.score(for: store.result)
    }

    // MARK: Streak

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<7, id: \.self) { i in
                let day = Calendar.current.date(
                    byAdding: .day, value: i - 6,
                    to: Calendar.current.startOfDay(for: Date())) ?? Date()
                let logged = store.loggedDays.contains(day)
                Circle()
                    .fill(logged ? accent : .clear)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(
                        logged ? .clear : Theme.dim.opacity(0.35), lineWidth: 1.5))
            }
            Spacer()
            Text(streakLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
        }
    }

    private var streakLabel: String {
        let current = store.streak?.current ?? 0
        let best    = store.streak?.best ?? 0
        if current > 0, current == best, current > 2 { return "\(current) mornings — your best run yet" }
        return "\(current) mornings in a row"
    }

    /// Only while the range is still forming. Once firm it is noise, and its
    /// old 60-day target implied sixty mornings of work before anything
    /// happened — the score actually starts on the second.
    @ViewBuilder
    private var baselineBar: some View {
        let logged = store.streak?.totalAnchors ?? 0
        if logged < AnchorBaseline.firmAnchors {
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: Double(logged),
                             total: Double(AnchorBaseline.firmAnchors))
                    .tint(Theme.breathe)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
                Text("\(logged) of \(AnchorBaseline.firmAnchors) readings · your range is still forming")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: Expanded

    @ViewBuilder
    private var expandedBody: some View {
        if let anchor = store.anchor {
            Text(anchorMeta(anchor))
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
        if store.recent.count >= 2 {
            AnchorSparkline(scores: store.recent, accent: accent)
        }
        if let raw = store.insight {
            let parsed = DayPotentialInsight(raw: raw)
            ForEach(Array(parsed.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(accent.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(styled(bullet))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
            }
            if let rec = parsed.recommendation {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accent)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WHAT TODAY CAN HOLD")
                            .font(Theme.monoLabel)
                            .foregroundStyle(accent)
                        Text(rec)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
            }
        }
        if let load = store.loadLine {
            Divider().overlay(Theme.dim.opacity(0.2))
            Text("HOW THE DAY HAS GONE SO FAR")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
            Text(styled(load))
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    /// Shown only while today's read is still open — it disappears the moment
    /// the anchor lands.
    private var nudge: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.warn)
            Text("Three quiet minutes with the strap on keeps it going.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.warn.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Theme.warn.opacity(0.25), lineWidth: 0.5))
    }

    private func anchorMeta(_ a: AnchorReading) -> String {
        let mins = Int((a.durationSec / 60).rounded())
        let hh = Int(a.hour)
        let mm = Int((a.hour - Double(hh)) * 60)
        return String(format: "%@ · %02d:%02d · %d MIN STILL",
                      a.late ? "LATER READ" : "MORNING READ", hh, mm, mins)
    }

    private func styled(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attr[run.range].foregroundColor = Theme.text
        }
        return attr
    }
}

/// Recent morning scores as bars — one day means little, the run is the point.
struct AnchorSparkline: View {
    let scores: [Int]
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(scores.enumerated()), id: \.offset) { idx, score in
                RoundedRectangle(cornerRadius: 3)
                    .fill(idx == scores.count - 1 ? accent : Theme.dim.opacity(0.35))
                    .frame(height: max(6, CGFloat(score) * 0.42))
            }
        }
        .frame(height: 46)
    }
}
