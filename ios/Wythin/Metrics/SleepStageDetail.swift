import Foundation

/// The four-stage breakdown: awake, REM, light, deep.
///
/// **Read the caveat before reading the minutes.** Three states is what a
/// cardiac signal supports honestly, and it remains what the score is built
/// on. This is the finer split, provided because it is the vocabulary everyone
/// knows and because seeing the night's shape is worth something — but
/// independent validation puts consumer four-stage agreement with
/// polysomnography at κ 0.21–0.53, and the light/deep boundary is the one a
/// chest strap places worst.
///
/// Two honest limits specific to this implementation:
///
/// 1. **N1 is not reported.** It is roughly 5% of a night, human scorers agree
///    on it at κ 0.24 — worse than any other stage — and no cardiac method in
///    the literature recovers it. It is folded into light.
/// 2. **The proportions are imposed, not discovered.** Ticks are ranked on a
///    depth axis and cut at typical adult shares. That means the *ordering* is
///    measured and the *totals* are assumed, so a night with unusually little
///    deep sleep will still be reported near the typical share. Trust the
///    shape; do not read the minutes as a measurement.
enum SleepStageDetail: Int, CaseIterable {
    case wake = 0, rem = 1, light = 2, deep = 3

    var label: String {
        switch self {
        case .wake:  return "Awake"
        case .rem:   return "REM"
        case .light: return "Light"
        case .deep:  return "Deep"
        }
    }
}

extension SleepStages {

    /// Typical adult shares of *sleep* time, used as the cut points.
    private static let deepShare = 0.21
    private static let remShare = 0.23

    /// Splits a night into four stages.
    ///
    /// The axis is a within-night depth score: coherence up, SDNN down, LF/HF
    /// down, heart rate down — each standardised against this night, because
    /// the absolute values from the literature do not transfer to this app's
    /// signal definitions. A time term tilts the axis across the night, since
    /// deep sleep is front-loaded and REM lengthens toward morning; without it
    /// the two ends of the axis are only "calm" and "not calm", with no way to
    /// tell early light sleep from late REM.
    static func detailed(_ points: [MetricsHistoryPoint]) -> [SleepStageDetail] {
        let coarse = classify(points)
        guard !points.isEmpty else { return [] }

        let asleep = coarse.indices.filter { coarse[$0] != .wake }
        guard asleep.count > 10 else {
            return coarse.map { $0 == .wake ? .wake : .light }
        }

        func z(_ values: [Float?]) -> [Double] {
            let present = values.compactMap { $0 }.map(Double.init)
            guard present.count > 1 else { return values.map { _ in 0 } }
            let mean = present.reduce(0, +) / Double(present.count)
            let sd = sqrt(present.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(present.count))
            guard sd > 0 else { return values.map { _ in 0 } }
            return values.map { $0.map { (Double($0) - mean) / sd } ?? 0 }
        }

        let zc = z(points.map(\.coherence))
        let zs = z(points.map(\.sdnn))
        let zl = z(points.map(\.lfHF))
        let zh = z(points.map(\.meanBPM))

        // Depth, plus a tilt: early ticks lean deep, late ticks lean REM.
        let span = Double(max(1, asleep.count))
        var scored: [(index: Int, depth: Double)] = []
        for (rank, i) in asleep.enumerated() {
            let through = Double(rank) / span
            let tilt = (0.5 - through) * 1.2
            scored.append((i, zc[i] - zs[i] - zl[i] - zh[i] + tilt))
        }

        let byDepth = scored.sorted { $0.depth > $1.depth }
        let deepCount = Int(Double(byDepth.count) * deepShare)
        let remCount = Int(Double(byDepth.count) * remShare)

        var out = [SleepStageDetail](repeating: .light, count: points.count)
        for i in coarse.indices where coarse[i] == .wake { out[i] = .wake }
        for (n, entry) in byDepth.enumerated() {
            if n < deepCount { out[entry.index] = .deep }
            else if n >= byDepth.count - remCount { out[entry.index] = .rem }
            else { out[entry.index] = .light }
        }
        return smoothDetail(out, points: points)
    }

    /// Same run-length rule as the coarse pass: a stage briefer than a few
    /// minutes is a transition or a dropped estimate, not a stage.
    private static func smoothDetail(_ raw: [SleepStageDetail],
                                     points: [MetricsHistoryPoint]) -> [SleepStageDetail] {
        guard raw.count > 2, points.count == raw.count else { return raw }
        let tick = points.count > 1
            ? points[1].timestamp.timeIntervalSince(points[0].timestamp)
            : 30
        let minRun = max(1, Int(SleepThresholds.minStageRunSec / max(tick, 1)))
        var out = raw
        for _ in 0..<4 {
            var changed = false
            var i = 0
            while i < out.count {
                var j = i
                while j + 1 < out.count && out[j + 1] == out[i] { j += 1 }
                if (j - i + 1) < minRun {
                    let before: SleepStageDetail? = i > 0 ? out[i - 1] : nil
                    let after: SleepStageDetail? = j + 1 < out.count ? out[j + 1] : nil
                    if let replacement = before ?? after, replacement != out[i] {
                        for k in i...j { out[k] = replacement }
                        changed = true
                    }
                }
                i = j + 1
            }
            if !changed { break }
        }
        return out
    }
}
