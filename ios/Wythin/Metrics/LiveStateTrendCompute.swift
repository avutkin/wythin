import Foundation

// MARK: - MetricTrend

struct MetricTrend {
    let start: Float?
    let end:   Float?
    let min:   Float?
    let max:   Float?
    let mean:  Float?
    let direction: String   // "rising" | "falling" | "stable"
    /// Today's average for this metric. Retained for the local day-load
    /// line — it is deliberately NOT sent to the live-state prompt.
    let dayMean: Float?

    let buckets:    [Float]?    // 5 × 2-min means, oldest first
    let slopePct:   Float?      // (last − first) / |first| × 100
    let volatility: String?     // "low" | "moderate" | "high"
    let shape:      String?     // TrendShape.rawValue

    init(start: Float?, end: Float?, min: Float?, max: Float?, mean: Float?,
         direction: String, dayMean: Float? = nil,
         buckets: [Float]? = nil, slopePct: Float? = nil,
         volatility: String? = nil, shape: String? = nil) {
        self.start = start
        self.end = end
        self.min = min
        self.max = max
        self.mean = mean
        self.direction = direction
        self.dayMean = dayMean
        self.buckets = buckets
        self.slopePct = slopePct
        self.volatility = volatility
        self.shape = shape
    }
}

// MARK: - LiveStateTrendCompute

enum LiveStateTrendCompute {

    /// Metric keys, matching the backend's expected `metrics` dict keys.
    private static let keyPaths: [(key: String, path: (MetricsHistoryPoint) -> Float?)] = [
        ("hr",         { $0.meanBPM }),
        ("rmssd",      { $0.rmssd }),
        ("rsa",        { $0.rsaMs }),
        ("sdnn",       { $0.sdnn }),
        ("lf_hf",      { $0.lfHF }),
        ("coherence",  { $0.coherence }),
        ("breath_bpm", { $0.breathBPM }),
        ("cbi",        { $0.cbi }),
        ("pip",        { $0.pip }),     // inner noise — focus proxy
        ("dfa1",       { $0.dfa1 }),    // fractal organization — focus proxy
        ("dc",         { $0.dc }),      // vagal tone (deceleration capacity)
        ("rcmse",      { $0.rcmse }),   // adaptive capacity (entropy)
        ("vti",        { $0.vti }),     // calm power (vagal tone index)
    ]

    /// Minimum quality-passing points required in the window before summarizing
    /// (≈2 minutes at 2 s/tick).
    static let minimumPoints = 30

    /// Summarizes the last `windowMinutes` of quality-filtered history into one
    /// MetricTrend per core metric. Returns nil if there isn't enough valid
    /// data yet.
    static func summarize(_ history: [MetricsHistoryPoint], windowMinutes: Int = 10, now: Date = .now) -> [String: MetricTrend]? {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        let window = history.filter { $0.timestamp >= cutoff }
        guard window.count >= minimumPoints else { return nil }

        // Bucket edges come from timestamps, not counts, so a gap in the data
        // doesn't silently shift the arc the model reads.
        let bucketCount = 5
        let bucketSec   = Double(windowMinutes) * 60 / Double(bucketCount)

        var result: [String: MetricTrend] = [:]
        for (key, path) in keyPaths {
            let values = window.compactMap(path)
            guard !values.isEmpty else { continue }
            // Day average: mean over the full history passed in (today's points).
            let dayValues = history.compactMap(path)
            let dayMean = dayValues.isEmpty ? nil : dayValues.reduce(0, +) / Float(dayValues.count)

            var buckets: [Float] = []
            for i in 0..<bucketCount {
                let lo = cutoff.addingTimeInterval(Double(i) * bucketSec)
                let hi = cutoff.addingTimeInterval(Double(i + 1) * bucketSec)
                let inBucket = window
                    .filter { $0.timestamp >= lo && $0.timestamp < hi }
                    .compactMap(path)
                guard !inBucket.isEmpty else { buckets = []; break }
                buckets.append(inBucket.reduce(0, +) / Float(inBucket.count))
            }

            result[key] = trend(for: values,
                                dayMean: dayMean,
                                buckets: buckets.count == bucketCount ? buckets : nil)
        }
        guard !result.isEmpty else { return nil }
        return result
    }

    private static func trend(for values: [Float], dayMean: Float?, buckets: [Float]? = nil) -> MetricTrend {
        let startVal = values.first
        let endVal   = values.last
        let minVal   = values.min()
        let maxVal   = values.max()
        let meanVal  = values.reduce(0, +) / Float(values.count)

        let direction: String
        if values.count >= 2 {
            let mid = values.count / 2
            let firstHalf  = Array(values[..<mid])
            let secondHalf = Array(values[mid...])
            let firstMean  = firstHalf.reduce(0, +) / Float(firstHalf.count)
            let secondMean = secondHalf.reduce(0, +) / Float(secondHalf.count)
            let relChange  = abs(secondMean - firstMean) / max(abs(firstMean), 1e-6)
            if relChange > 0.05 {
                direction = secondMean > firstMean ? "rising" : "falling"
            } else {
                direction = "stable"
            }
        } else {
            direction = "stable"
        }

        var slopePct: Float?
        var volatility: String?
        var shape: String?
        if let buckets, let first = buckets.first, let last = buckets.last, abs(first) > 1e-6 {
            slopePct   = (last - first) / abs(first) * 100
            volatility = TrendShapeCompute.volatility(buckets)
            shape      = TrendShapeCompute.classify(buckets).rawValue
        }

        return MetricTrend(start: startVal, end: endVal, min: minVal, max: maxVal,
                           mean: meanVal, direction: direction, dayMean: dayMean,
                           buckets: buckets, slopePct: slopePct,
                           volatility: volatility, shape: shape)
    }
}
