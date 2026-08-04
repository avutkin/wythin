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
            crownRow
            weekRow
            crownProgressBar
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

    // MARK: Crowns

    /// Cumulative mornings recorded, ever. `StreakCompute` already totals it,
    /// and the ladder, the progress bar and the nudge copy all read this one
    /// number so they cannot disagree about how much history exists.
    private var totalMornings: Int {
        store.streak?.totalAnchors ?? 0
    }

    private var crownRow: some View {
        HStack(spacing: 7) {
            ForEach(Array(CrownLadder.tokens(forMorningCount: totalMornings).enumerated()),
                    id: \.offset) { _, token in
                crownIcon(token)
            }
            Spacer()
            if let count = DayPotentialCrownCopy.countLabel(current: store.streak?.current ?? 0, total: totalMornings) {
                Text(count)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    @ViewBuilder
    private func crownIcon(_ token: CrownToken) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "crown.fill")
                .font(.system(size: 11))
                .foregroundStyle(crownColor(token.color))
            if let overflow = token.overflowCount {
                Text("×\(overflow)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    /// Fixed per tier, not band-derived — the ladder marks accumulated
    /// history, so it must not flicker with today's reading.
    private func crownColor(_ c: CrownToken.Color) -> Color {
        switch c {
        case .white:  return Theme.text
        case .yellow: return Theme.domainHeavy
        case .red:    return Theme.warn
        case .green:  return Theme.accent
        }
    }

    // MARK: This week

    private static let weekdayLetters = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    /// Monday-through-Sunday context for the current calendar week, spread
    /// across the same width as the capsule beneath it so each letter sits
    /// above roughly its own share of the bar.
    ///
    /// This used to draw a small crown under each letter — a day's own
    /// attendance mark, deliberately a different measurement than the
    /// ladder above it. That mark is gone now: the capsule beneath already
    /// carries the week's progress at real size, and a row of seven more
    /// crowns above it and a row of earned crowns above *that* read as
    /// "crowns, crowns, and more crowns" rather than adding information.
    /// The letters alone still answer "what week is this", which is all
    /// this row ever needed to do next to the bar.
    private var weekRow: some View {
        let cells = DayPotentialWeekRow.cells(loggedDays: store.loggedDays, today: Date())
        return HStack(spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(Self.weekdayLetters[index])
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(cell.isToday ? accent : Theme.dim)
                    .frame(maxWidth: .infinity)
            }
        }
        // Same horizontal extent as the capsule below, so the two rows line
        // up: both are full-width flex rows inside the same leading-aligned
        // stack, with no independent padding of their own to drift them
        // apart.
    }

    // MARK: Next-crown progress bar geometry

    private static let barHeight: CGFloat = 36
    /// The capsule's own visual thickness — roughly half of `barHeight`, the
    /// row's full allotted height, so the track reads as a line rather than
    /// the slab it used to be. `barHeight` stays taller than this on
    /// purpose: it leaves room for the travelling marker below to overflow
    /// the thin track a little, the way a slider's thumb sits proud of a
    /// thin rail, without being clipped by the row.
    private static let trackHeight: CGFloat = 18
    /// The travelling marker's fixed square footprint. Giving it an actual
    /// frame — rather than letting the crown glyph's own rendered bounds
    /// decide it — is what lets `DayPotentialBarGeometry.markerCenterX`
    /// clamp correctly: the clamp needs a real half-width, not a guess.
    private static let markerSize: CGFloat = 20
    /// Reserved at the trailing end for the crown, held out of the fill
    /// track entirely — earning a full week must not paint the fill straight
    /// under the icon, since the reference always shows that milestone
    /// sitting on the capsule's unlit portion.
    private static let crownSlotWidth: CGFloat = 34

    /// Fills toward whichever crown the ladder above is currently building —
    /// the cumulative count, same as the ladder, not this week's attendance.
    ///
    /// Two crowns ride this bar, and they are one crown at two moments, not
    /// two decorations. The travelling white crown *is* the in-progress
    /// week — a white crown is exactly what the ladder above calls a week
    /// that hasn't closed yet — moving toward the trailing crown, which is
    /// that same week's future: the specific colour it becomes once it
    /// closes. The trailing crown is a silhouette of that colour, not a
    /// neutral placeholder: it is tinted with `nextCrownColor` the whole
    /// time it's outlined, then fills solid the instant it's earned, so the
    /// colour never changes at the moment of completion — only the fill
    /// does, which is the same instant the travelling crown reaches it. The
    /// copy beneath names this same colour, from this same function, so the
    /// sentence and the silhouette cannot disagree.
    private var crownProgressBar: some View {
        let fraction = CrownLadder.progressFraction(forMorningCount: totalMornings)
        let earned = fraction >= 1.0
        let nextColor = crownColor(CrownLadder.nextCrownColor(forMorningCount: totalMornings))

        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let trackWidth = max(geo.size.width - Self.crownSlotWidth, 0)
                let fillWidth = DayPotentialBarGeometry.fillWidth(fraction: fraction, trackWidth: trackWidth)
                let markerX = DayPotentialBarGeometry.markerCenterX(
                    fraction: fraction, trackWidth: trackWidth, markerRadius: Self.markerSize / 2)

                ZStack(alignment: .leading) {
                    // Beyond the fill: near-black track, not empty space.
                    // Constrained to `trackHeight` and left otherwise
                    // unpositioned so the ZStack's own leading/centre
                    // alignment centres it vertically in the taller row.
                    Capsule().fill(Theme.bg)
                        .frame(height: Self.trackHeight)

                    // The fill itself, with a faint lighter core line for
                    // depth — subtle on purpose, it is not the fill boundary
                    // marker, the crown below is.
                    Capsule()
                        .fill(accent)
                        .frame(width: fillWidth, height: Self.trackHeight)
                        .overlay(alignment: .leading) {
                            if fillWidth > 16 {
                                Capsule()
                                    .fill(Theme.text.opacity(0.16))
                                    .frame(width: fillWidth - 12, height: 2)
                                    .padding(.leading, 6)
                            }
                        }

                    // The marker at the fill boundary: a white crown,
                    // because the boundary it marks is literally the week
                    // in progress, the same thing a white crown means in
                    // the ladder above. Deliberately toned down from a
                    // plain white fill — a muted opacity of `Theme.text`
                    // rather than the pure colour — and with no glow behind
                    // it: the earlier glow was purely decorative, so
                    // dropping it removes brightness without losing any
                    // information a Reduce Transparency or low-vision
                    // rendering would otherwise lose. It stays legible
                    // against both the fill and the dark remainder on
                    // shape and position alone.
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text.opacity(0.82))
                        .frame(width: Self.markerSize, height: Self.markerSize)
                        .position(x: markerX, y: geo.size.height / 2)

                    // The milestone crown, inside the capsule at the
                    // trailing end, on the reserved dark slot. At
                    // `trackHeight` this still sits comfortably inside the
                    // capsule, so it stays put on the centreline rather
                    // than needing to move outside the track.
                    Image(systemName: earned ? "crown.fill" : "crown")
                        .font(.system(size: 13))
                        .foregroundStyle(nextColor)
                        .position(x: geo.size.width - Self.crownSlotWidth / 2, y: geo.size.height / 2)
                }
            }
            .frame(height: Self.barHeight)
            // The bar only moves in whole-day steps when the store's
            // morning count changes; animating that jump — under any
            // Reduce Motion setting or not — would read as motion for its
            // own sake rather than carrying information, so it is switched
            // off outright rather than gated on the accessibility setting.
            .transaction { $0.animation = nil }

            Text(DayPotentialCrownCopy.nudgeText(forMorningCount: totalMornings))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)
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
