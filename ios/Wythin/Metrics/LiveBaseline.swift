import Foundation

/// Typical within-person spread for the live metrics, used as a prior so a
/// baseline built from two or three days can still be scored.
///
/// UNCALIBRATED. These are order-of-magnitude guesses, not this user's figures,
/// chosen so that an early z is conservative rather than absent. They dominate
/// at one day and are nearly irrelevant by twenty. Recalibrate once ~30 days of
/// rollups carrying SD exist. See `BaselinePrior` for the same pattern applied
/// to the morning anchor.
enum LivePrior {
    /// Days of history before the baseline is the user's own rather than mostly
    /// prior. A label threshold, not a compute gate — scoring starts at day one.
    static let firmDays = 7

    static func prior(for metric: LiveMetric) -> Float {
        switch metric {
        case .hr:        return 8      // bpm
        case .rmssd:     return 14     // ms
        case .rsa:       return 25     // ms
        case .sdnn:      return 30     // ms
        case .stressBalance: return 10 // SNS share, percentage points (0–100)
        case .coherence: return 0.18   // 0-1
        case .breathBPM: return 3      // breaths/min
        case .cbi:       return 0.15   // 0-1
        case .pip:       return 8      // %
        case .dfa1:      return 0.20   // unitless
        case .dc:        return 4      // ms
        case .rcmse:     return 0.35   // unitless
        case .vti:       return 0.6    // ln units
        }
    }
}

/// The user's own live norm, built from cached daily rollups.
///
/// Nothing here is population-referenced — every comparison is against the same
/// person. The centre is where their days sit; the spread is how much a normal
/// day moves around inside itself, which is what a ten-minute window is drawn
/// from.
struct LiveBaseline {
    private let stats: [String: BaselineStat]
    let dayCount: Int

    var provisional: Bool { dayCount < LivePrior.firmDays }

    func stat(for metric: LiveMetric) -> BaselineStat? { stats[metric.rawValue] }

    /// z against the prior-blended, prediction-widened spread. Nil when the
    /// metric has no history at all.
    func z(_ value: Float, for metric: LiveMetric) -> Float? {
        stat(for: metric)?.z(value, prior: LivePrior.prior(for: metric))
    }

    static func build(rollups: [DailyRollup], now: Date = .now) -> LiveBaseline? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -AnchorBaseline.windowDays,
                                           to: now) ?? .distantPast
        let inWindow = rollups.filter { $0.day >= cutoff }
        guard !inWindow.isEmpty else { return nil }

        var stats: [String: BaselineStat] = [:]
        for metric in LiveMetric.allCases {
            let key = metric.rawValue
            // Both mean AND sd required: a day counted toward the centre or `n`
            // but silently skipped by the variance loop below would let `n`
            // overstate how much evidence backs the spread, which is what
            // `BaselineStat.sdBlended` uses to decide how much to trust it over
            // the prior.
            let days = inWindow.filter { $0.mean[key] != nil && $0.sd[key] != nil }
            guard !days.isEmpty else { continue }

            let centre = days.compactMap { $0.mean[key] }.reduce(0, +) / Double(days.count)

            // Pooled within-day variance, weighted by how many samples of THIS
            // metric each day actually had — not by the day's total tick count.
            // A three-minute day must not count as much as a fourteen-hour one,
            // and equally a metric that computed twice inside a fourteen-hour
            // day must not carry that day's weight: DC and RCMSE need long
            // clean stretches and are routinely absent from most ticks.
            //
            // `?? d.sampleCount` covers rollups written before `count` existed.
            // `TrackCache.rollupComputeVersion` 4 discards every such rollup, so
            // it is unreachable from disk; it only keeps hand-built fixtures
            // that predate the field behaving as they did.
            var weightSum = 0.0
            var varSum    = 0.0
            for d in days {
                guard let sd = d.sd[key] else { continue }
                let w = Double(max(d.count[key] ?? d.sampleCount, 1))
                varSum    += w * sd * sd
                weightSum += w
            }
            let spread = weightSum > 0 ? (varSum / weightSum).squareRoot() : 0

            stats[key] = BaselineStat(mean: Float(centre), sd: Float(spread), n: days.count)
        }
        guard !stats.isEmpty else { return nil }
        return LiveBaseline(stats: stats, dayCount: inWindow.count)
    }
}
