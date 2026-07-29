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
/// The cache key includes a fingerprint of the page's rollup *values*, so
/// paging back to a past period is free while a period whose data actually
/// changed regenerates.
@MainActor
func macroRead(for period: TrackPeriod,
               range: TrackRange,
               series: [(spec: TrackMetricSpec, series: TrackSeries)],
               cache: TrackCache,
               client: APIClient) async -> String? {
    let key = "\(period.apiValue)|\(range.start.timeIntervalSince1970)|\(cache.fingerprint(for: range.days))"
    if let cached = cache.macroRead(key: key) { return cached }

    let payload = MacroTrendPayload(period: period, rangeLabel: range.label, series: series)
    guard !payload.trends.isEmpty,
          let response = try? await client.generateMacroTrendInsight(payload) else { return nil }

    cache.setMacroRead(response.text, key: key)
    return response.text
}
