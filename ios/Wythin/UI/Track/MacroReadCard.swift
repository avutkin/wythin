import SwiftUI

/// One line of a parsed macro read: a `•` trend bullet, a `→` action for the
/// coming period, or — for a reply that doesn't match either marker — plain
/// prose. Split out from `MacroReadCard` so the classification (which is
/// pure string logic, no SwiftUI) is directly unit-testable without a view-
/// hosting harness, the same reasoning `LiveStateInsight` already applies to
/// the Live widget's reply.
struct MacroReadLine: Equatable {
    enum Kind: Equatable { case bullet, action, prose }
    let kind: Kind
    /// The leading marker (`•`/`→`) stripped and whitespace trimmed. For
    /// `.prose` this is just the trimmed line — there is no marker to strip.
    let text: String

    /// Splits on newlines and classifies each non-empty line. A reply that
    /// doesn't match the prompt's bulleted shape at all — the old "two
    /// sentences" shape, or anything else unexpected — comes back as
    /// `.prose` rather than being dropped, so an unrecognised reply still
    /// renders as plain text instead of the card silently going blank.
    static func parse(_ raw: String) -> [MacroReadLine] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.hasPrefix("•") {
                    return MacroReadLine(kind: .bullet,
                                          text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                if line.hasPrefix("→") {
                    return MacroReadLine(kind: .action,
                                          text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                return MacroReadLine(kind: .prose, text: line)
            }
    }
}

/// Up to three `•` bullets reading the period (accent dot, proportional body
/// font, `**bold**` key ideas brightened — the same treatment
/// `LiveStateWidget`'s WHAT THIS MEANS bullets use) plus one or two `→`
/// actions in an accent-tinted block matching `LiveStateWidget`'s RIGHT NOW
/// block. This card used to render both in `Theme.monoBody`/`Theme.monoLabel`
/// — a leftover from before the rest of Track adopted the proportional font —
/// which made it look like it had drifted in from a different app. Absent
/// entirely on failure — a broken insight is not worth an error message at
/// the top of the screen.
struct MacroReadCard: View {
    let text: String?
    let isLoading: Bool

    var body: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.surface)
                        .frame(height: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .padding(.horizontal)
        } else if let text, !text.isEmpty {
            let lines = MacroReadLine.parse(text)
            let bullets = lines.filter { $0.kind == .bullet }
            let prose = lines.filter { $0.kind == .prose }
            let actions = lines.filter { $0.kind == .action }.map(\.text)
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                    bulletRow(line.text)
                }
                // Fallback for a reply that didn't match the bulleted shape
                // at all (see `MacroReadLine.parse`) — rendered plain, since
                // there is no bold-span convention to honor on prose.
                ForEach(Array(prose.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
                if !actions.isEmpty {
                    actionsBlock(actions)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .padding(.horizontal)
        }
    }

    private var header: some View {
        Text("MACRO READ")
            .font(Theme.monoLabel)
            .foregroundStyle(Theme.dim)
    }

    @ViewBuilder
    private func bulletRow(_ bullet: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.accent.opacity(0.7))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(MarkdownBullet.styled(bullet))
                .font(.system(size: 14))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    @ViewBuilder
    private func actionsBlock(_ actions: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent)
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Text(action)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.5))
    }
}

/// Cached text for this page, or a fresh call. Returns nil on any failure so
/// the card simply does not render; the next appear retries.
///
/// The key has four parts, and each one exists for a reason:
///
/// - **revision** (`TrackCache.macroReadRevision`) — a shipped prompt or
///   formatter fix must reach periods that are already cached. Without it a
///   past week, whose rollups will never change again, serves its original
///   text forever.
/// - **period** — a week and a month can share a start date, and their reads
///   are not interchangeable.
/// - **range start** — which page this is.
/// - **reference kind** — one character per metric, `1` when that metric's
///   reference line is the person's own 90-day baseline and `0` when it is
///   still the fixed norm. The rollups behind a past week stop changing, but
///   the *reference* they are described against does not: on day 10 a user
///   has too little history, so the read is phrased around "typical"; by day
///   25 the same week is charted against "your 90d". Without this the stale
///   "typical" text outlives the switch and contradicts the chart drawn
///   directly beneath it.
/// - **fingerprint** — a hash of the page's rollup *values*, so a period
///   whose data actually changed regenerates and one that did not is free.
@MainActor
func macroRead(for period: TrackPeriod,
               range: TrackRange,
               series: [(spec: TrackMetricSpec, series: TrackSeries)],
               cache: TrackCache,
               client: APIClient) async -> String? {
    let referenceKind = series.map { $0.series.referenceIsPersonal ? "1" : "0" }.joined()
    let key = "v\(TrackCache.macroReadRevision)"
            + "|\(period.apiValue)"
            + "|\(range.start.timeIntervalSince1970)"
            + "|\(referenceKind)"
            + "|\(cache.fingerprint(for: range.days))"
    if let cached = cache.macroRead(key: key) { return cached }

    let payload = MacroTrendPayload(period: period, rangeLabel: range.label, series: series)
    guard !payload.trends.isEmpty,
          let response = try? await client.generateMacroTrendInsight(payload) else { return nil }

    cache.setMacroRead(response.text, key: key)
    return response.text
}
