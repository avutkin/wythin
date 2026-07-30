import SwiftUI

/// Two sentences of LLM read plus one or two `→` actions. Absent entirely on
/// failure — a broken insight is not worth an error message at the top of the
/// screen.
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
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(Array(lines(text).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(line.hasPrefix("→") ? Theme.monoLabel : Theme.monoBody)
                        .foregroundStyle(line.hasPrefix("→") ? Theme.accent : Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
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

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
