import Foundation

/// Tuning for the live read. UNCALIBRATED — first guesses, chosen so the four
/// quadrants in the spec behave as described. `gainClampLow` is the
/// consequential one: at 0.25 a high level nearly ignores a slope, which is the
/// intended behaviour, but it also means a genuine collapse from a high level
/// takes longer to register.
enum LiveThresholds {
    /// Smallest worthwhile change, in personal SD per window. Below this a
    /// slope is not a trend — it is noise, and reporting it is how the widget
    /// ends up with a story every time it looks.
    static let swc: Float = 0.30
    /// How much a trend can be worth relative to a level, before the gain.
    static let trendGainK: Float = 0.5
    static let gainClampLow:  Float = 0.25
    static let gainClampHigh: Float = 1.5
    /// Fraction of the window that must carry samples, at whatever cadence the
    /// data was recorded. Expressed as coverage rather than a count so it holds
    /// at 2 s and at 30 s alike.
    static let minCoverage: Float = 0.6
    /// Ceiling on how much wall-clock time a single gap between consecutive
    /// samples can contribute to coverage.
    ///
    /// Coverage sums the gaps between consecutive valid samples: that is
    /// correct when the gaps *are* the cadence, but a single BLE dropout —
    /// `MetricsQualityFilter` rejecting everything in the middle of the
    /// window while the two edges stay clean — produces one enormous "gap"
    /// that is actually silence, not data. Left uncapped, two samples sitting
    /// at the two edges of a ten-minute window would sum to the full window
    /// and read as fully covered, which is the anchor-cadence bug's mirror
    /// image: this time the gate says "covered" when the strap was off for
    /// most of it.
    ///
    /// 60 s is comfortably above both real cadences this app produces — the
    /// 2 s foreground tick and the 30 s background tick — so neither is ever
    /// capped, while it sits well below the 600 s window, so a dropout is
    /// still charged for the silence it actually was.
    static let maxCredibleGapSec: Double = 60
    static let windowMinutes = 10

    /// Consecutive evaluations a new state must win before it is displayed.
    /// UNCALIBRATED first guess.
    static let hysteresisCount = 3
    /// A contribution below this is not worth a bullet. UNCALIBRATED first guess.
    static let contributionFloor: Float = 0.25
    /// When no axis exceeds this, nothing really moved and the call is weak.
    /// UNCALIBRATED first guess.
    static let weakCallCeiling: Float = 0.35
}

/// One metric's read over the window.
struct MetricReading: Equatable {
    let metric: LiveMetric
    /// Where the window sits against the person's usual, in their own SD.
    let level: Float
    /// Slope across the window in personal SD per window. Zero when gated.
    let trend: Float
    /// True when the slope cleared the smallest-worthwhile-change gate.
    let meaningful: Bool
    /// Level adjusted by the gain-weighted trend. What the classifier scores.
    let effective: Float
}

/// A ten-minute window, reduced to per-metric readings against the baseline.
struct LiveReading {
    let readings: [LiveMetric: MetricReading]
    /// Fraction of the window that carried samples.
    let coverage: Float

    /// Trend counts for less the higher the level already is, and for more the
    /// lower it is. This is the whole asymmetry in one line.
    static func gain(_ level: Float) -> Float {
        min(max(1 - level / 2, LiveThresholds.gainClampLow), LiveThresholds.gainClampHigh)
    }

    static func effective(level: Float, trend: Float) -> Float {
        level + LiveThresholds.trendGainK * gain(level) * trend
    }

    static func build(window: [MetricsHistoryPoint],
                      baseline: LiveBaseline,
                      windowMinutes: Int = LiveThresholds.windowMinutes,
                      now: Date = .now) -> LiveReading? {

        let valid = MetricsQualityFilter.filter(window).sorted { $0.timestamp < $1.timestamp }
        guard valid.count >= 2 else { return nil }

        // Coverage, inferred from the data's own spacing rather than assumed.
        // Each gap is capped at `maxCredibleGapSec` before it's summed, so a
        // long silence (dropout) is charged for the silence it was instead of
        // masquerading as one big, perfectly-spaced tick.
        let windowSec = Double(windowMinutes) * 60
        let spans     = zip(valid, valid.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
        let cadence   = spans.sorted()[spans.count / 2]
        let covered   = spans.reduce(0) { $0 + min($1, LiveThresholds.maxCredibleGapSec) }
                      + min(cadence, LiveThresholds.maxCredibleGapSec)
        let coverage  = Float(min(covered / windowSec, 1))
        guard coverage >= LiveThresholds.minCoverage else { return nil }

        var readings: [LiveMetric: MetricReading] = [:]
        for metric in LiveMetric.allCases {
            let values = valid.compactMap { metric.value($0) }
            guard values.count >= 2,
                  let median = AnchorDetector.median(values),
                  let level  = baseline.z(median, for: metric),
                  let sd     = baseline.stat(for: metric)?.sdBlended(prior: LivePrior.prior(for: metric))
            else { continue }

            // Slope across the window, expressed in the person's own SD so it is
            // comparable between metrics. 8% of one metric and 8% of another are
            // unrelated magnitudes; 0.4 SD means the same thing everywhere.
            // Split by index over this metric's own present samples, not by
            // wall clock — assumes a metric that computes at all is roughly
            // evenly present across the window, which every current caller
            // satisfies.
            let half  = values.count / 2
            let early = values.prefix(half)
            let late  = values.suffix(values.count - half)
            let earlyMean = early.reduce(0, +) / Float(early.count)
            let lateMean  = late.reduce(0, +) / Float(late.count)
            let rawTrend  = (lateMean - earlyMean) / sd

            let meaningful = abs(rawTrend) >= LiveThresholds.swc
            let trend      = meaningful ? rawTrend : 0

            readings[metric] = MetricReading(
                metric:     metric,
                level:      level,
                trend:      trend,
                meaningful: meaningful,
                effective:  effective(level: level, trend: trend))
        }
        guard !readings.isEmpty else { return nil }
        return LiveReading(readings: readings, coverage: coverage)
    }
}
