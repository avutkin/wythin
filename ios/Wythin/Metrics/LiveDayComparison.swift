import Foundation

/// One day held against the person's last seven *recorded* days.
///
/// "Recorded" is the load-bearing word: calendar weeks lie whenever the strap
/// stayed in the drawer, so the reference is the most recent seven days with
/// at least thirty minutes of wear, looking as far back as the rollup cache
/// goes. Days without recordings are skipped, never counted.
enum LiveDayComparison {
    static let daysWanted = 7
    static let minWearSeconds: Double = 30 * 60
    /// Below this many qualifying days there is no comparison at all — one
    /// day of history is an anecdote, not a norm.
    static let minDays = 2

    /// z-band edges shared by every consumer: inside ±0.5 SD a shift is a
    /// normal day and renders neutral; saturation is reached at 2 SD.
    static let neutralZ: Float = 0.5
    static let saturationZ: Float = 2.0

    /// The most recent `daysWanted` rollups strictly before `day` that carry
    /// at least `minWearSeconds` of wear.
    static func referenceDays(rollups: [DailyRollup], before day: Date) -> [DailyRollup] {
        Array(
            rollups
                .filter { $0.day < day && $0.wearSeconds >= minWearSeconds }
                .sorted { $0.day > $1.day }
                .prefix(daysWanted)
        )
    }

    static func reference(rollups: [DailyRollup], before day: Date) -> LiveDayReference? {
        let days = referenceDays(rollups: rollups, before: day)
        guard days.count >= minDays else { return nil }

        // Same centre/spread construction as LiveBaseline.build, over the
        // selected days: centre is the unweighted mean of daily means, spread
        // is the pooled within-day SD weighted by that metric's own sample
        // count per day. Both mean AND sd must exist for a day to count.
        var stats: [String: BaselineStat] = [:]
        for metric in LiveMetric.allCases {
            let key = metric.rawValue
            let usable = days.filter { $0.mean[key] != nil && $0.sd[key] != nil }
            guard !usable.isEmpty else { continue }

            let centre = usable.compactMap { $0.mean[key] }.reduce(0, +) / Double(usable.count)

            var weightSum = 0.0
            var varSum    = 0.0
            for d in usable {
                guard let sd = d.sd[key] else { continue }
                let w = Double(max(d.count[key] ?? d.sampleCount, 1))
                varSum    += w * sd * sd
                weightSum += w
            }
            let spread = weightSum > 0 ? (varSum / weightSum).squareRoot() : 0
            stats[key] = BaselineStat(mean: Float(centre), sd: Float(spread), n: usable.count)
        }
        guard !stats.isEmpty else { return nil }
        return LiveDayReference(stats: stats, dayCount: days.count)
    }

    /// Which way "better" points for each live metric. Read from
    /// `activityMetricDefs` wherever a metric has a def, so a tile and the
    /// session detail can never disagree about what counts as an improvement;
    /// the switch spells out the rest. It stays exhaustive on purpose: a new
    /// `LiveMetric` case must choose a direction, not inherit one. Harmony's
    /// optimum is a target, not a direction — the old `higherBetter: false`
    /// tile flag colored a move from 0.7 toward 1.0 as bad.
    static func direction(for metric: LiveMetric) -> BenefitDirection {
        switch metric {
        case .dc, .rcmse, .pip, .dfa1, .stressBalance, .rsa, .rmssd, .hr:
            return metricDef(metric).direction
        case .sdnn, .vti, .coherence, .cbi:
            return .higher
        case .breathBPM:
            return .lower
        }
    }
}

/// Per-metric centre/spread over the reference days.
struct LiveDayReference: Equatable {
    let stats: [String: BaselineStat]
    let dayCount: Int

    func stat(for metric: LiveMetric) -> BaselineStat? { stats[metric.rawValue] }
}

/// One tile's day-versus-reference comparison, ready to render.
struct LiveDayDelta: Equatable {
    /// Raw signed % of the value vs the reference mean — what the tile prints.
    let percent: Float
    /// Prior-blended z of the value against the reference spread — what the
    /// tile *colors* by, so metrics with different natural variability can't
    /// lie: ±10% on RSA is a shrug, ±10% on resting pulse is not.
    let z: Float
    /// Whether the move is good for this metric (benefit-signed, so a falling
    /// Pulse and a DFA α1 approaching 1.0 are both `true`).
    let beneficial: Bool
    let referenceMean: Float

    var neutral: Bool { abs(z) < LiveDayComparison.neutralZ }

    /// Wash/text intensity: 0 inside the noise band, then a linear ramp from
    /// 0.35 at the band edge to 1.0 at `saturationZ`.
    var intensity: Float {
        let az = abs(z)
        guard az >= LiveDayComparison.neutralZ else { return 0 }
        let span = LiveDayComparison.saturationZ - LiveDayComparison.neutralZ
        let t = min(1, (az - LiveDayComparison.neutralZ) / span)
        return 0.35 + 0.65 * t
    }

    static func compute(value: Float,
                        metric: LiveMetric,
                        reference: LiveDayReference) -> LiveDayDelta? {
        guard let stat = reference.stat(for: metric),
              abs(stat.mean) > 1e-6,
              let z = stat.z(value, prior: LivePrior.prior(for: metric))
        else { return nil }

        let direction = LiveDayComparison.direction(for: metric)
        return LiveDayDelta(
            percent: (value - stat.mean) / abs(stat.mean) * 100,
            z: z,
            beneficial: direction.benefit(Double(value)) > direction.benefit(Double(stat.mean)),
            referenceMean: stat.mean
        )
    }
}
