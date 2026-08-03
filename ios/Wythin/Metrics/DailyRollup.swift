import Foundation

/// One local day's average of every metric the Track screen charts.
///
/// Track never reads raw `HRVSample`s: all-day recording writes a tick every
/// ~2 s (43,200 rows/day), so six months is ~7.8M rows. Rollups collapse that
/// to one small record per day, computed once and cached on disk.
struct DailyRollup: Codable, Equatable, Identifiable {
    /// Start of the local day this rollup covers.
    let day: Date

    let dc:            Double?
    let rmssd:         Double?
    let rsaMs:         Double?
    let rcmse:         Double?
    let pip:           Double?
    let dfa1:          Double?
    let stressBalance: Double?
    /// Not charted today, but free to keep and awkward to backfill later.
    let vti:           Double?
    let meanBPM:       Double?

    /// Quality-passing ticks behind these averages.
    let sampleCount: Int
    /// Wear time implied by `sampleCount`, in seconds.
    let wearSeconds: Double

    /// Per-metric mean, keyed by `LiveMetric.rawValue`. Duplicates the typed
    /// fields above deliberately: the typed ones are the Track charts' contract
    /// and must not churn, while this is the keyed access the live baseline
    /// needs. Both are written from the same pass.
    let mean: [String: Double]

    /// Per-metric **within-day** standard deviation, keyed the same way.
    ///
    /// This is the spread a ten-minute window actually varies by. The spread of
    /// daily means is between-day variance and is much smaller — dividing by it
    /// would inflate every z-score.
    let sd: [String: Double]

    var id: Date { day }

    /// Declared explicitly because the custom `init(from:)` below suppresses
    /// Swift's automatic memberwise-initializer synthesis for the whole
    /// struct, not just `Decodable` conformance. `DailyRollupCompute.rollup`
    /// and the tests both construct a `DailyRollup` directly by field, so
    /// this keeps that call shape working.
    init(day: Date, dc: Double?, rmssd: Double?, rsaMs: Double?, rcmse: Double?,
         pip: Double?, dfa1: Double?, stressBalance: Double?, vti: Double?,
         meanBPM: Double?, sampleCount: Int, wearSeconds: Double,
         mean: [String: Double], sd: [String: Double]) {
        self.day           = day
        self.dc            = dc
        self.rmssd         = rmssd
        self.rsaMs         = rsaMs
        self.rcmse         = rcmse
        self.pip           = pip
        self.dfa1          = dfa1
        self.stressBalance = stressBalance
        self.vti           = vti
        self.meanBPM       = meanBPM
        self.sampleCount   = sampleCount
        self.wearSeconds   = wearSeconds
        self.mean          = mean
        self.sd            = sd
    }

    /// Decoded field by field so a rollup written before `mean`/`sd` existed
    /// still loads. `TrackCache.File` decodes `rollups` with `try`, and its
    /// `load()` treats a throw as corruption and empties the entire cache —
    /// `macroReads` with it. Invalidating stale rollups is
    /// `rollupComputeVersion`'s job, deliberately narrow; a decode failure here
    /// would be a blanket wipe instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day           = try c.decode(Date.self, forKey: .day)
        dc            = try c.decodeIfPresent(Double.self, forKey: .dc)
        rmssd         = try c.decodeIfPresent(Double.self, forKey: .rmssd)
        rsaMs         = try c.decodeIfPresent(Double.self, forKey: .rsaMs)
        rcmse         = try c.decodeIfPresent(Double.self, forKey: .rcmse)
        pip           = try c.decodeIfPresent(Double.self, forKey: .pip)
        dfa1          = try c.decodeIfPresent(Double.self, forKey: .dfa1)
        stressBalance = try c.decodeIfPresent(Double.self, forKey: .stressBalance)
        vti           = try c.decodeIfPresent(Double.self, forKey: .vti)
        meanBPM       = try c.decodeIfPresent(Double.self, forKey: .meanBPM)
        sampleCount   = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        wearSeconds   = try c.decodeIfPresent(Double.self, forKey: .wearSeconds) ?? 0
        mean          = try c.decodeIfPresent([String: Double].self, forKey: .mean) ?? [:]
        sd            = try c.decodeIfPresent([String: Double].self, forKey: .sd) ?? [:]
    }
}

enum DailyRollupCompute {

    /// A day needs five minutes of quality data (150 ticks at ~2 s) before it
    /// is charted at all. Matches the gate the old Track view applied.
    static let minTicks = 150

    /// Nominal seconds represented by one compute tick.
    static let tickSeconds: Double = 2

    /// Nil when the day has fewer than `minTicks` quality samples.
    ///
    /// Filtering happens here rather than at the call site so the gate is
    /// counted against valid ticks, never raw ones.
    static func rollup(day: Date, points: [MetricsHistoryPoint]) -> DailyRollup? {
        let valid = MetricsQualityFilter.filter(points)
        guard valid.count >= minTicks else { return nil }

        func mean(_ extract: (MetricsHistoryPoint) -> Double?) -> Double? {
            let vals = valid.compactMap(extract)
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }

        var means: [String: Double] = [:]
        var sds:   [String: Double] = [:]
        for metric in LiveMetric.allCases {
            let vals = valid.compactMap { metric.value($0).map(Double.init) }
            guard !vals.isEmpty else { continue }
            let m = vals.reduce(0, +) / Double(vals.count)
            means[metric.rawValue] = m
            guard vals.count >= 2 else { sds[metric.rawValue] = 0; continue }
            let variance = vals.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count - 1)
            sds[metric.rawValue] = variance.squareRoot()
        }

        return DailyRollup(
            day:           day,
            dc:            mean { $0.dc.map(Double.init) },
            rmssd:         mean { $0.rmssd.map(Double.init) },
            rsaMs:         mean { $0.rsaMs.map(Double.init) },
            rcmse:         mean { $0.rcmse.map(Double.init) },
            pip:           mean { $0.pip.map(Double.init) },
            dfa1:          mean { $0.dfa1.map(Double.init) },
            stressBalance: mean(stressBalance),
            vti:           mean { $0.vti.map(Double.init) },
            meanBPM:       mean { $0.meanBPM.map(Double.init) },
            sampleCount:   valid.count,
            wearSeconds:   Double(valid.count) * tickSeconds,
            mean:          means,
            sd:            sds
        )
    }

    /// Stress Balance is the breathing-robust 0–100 arousal dial, not a raw
    /// LF/HF ratio — there is no stored field for it, so it is derived per
    /// tick exactly as `ActivityMetricsGrid.swift:58` does, then averaged.
    ///
    /// Delegates to `LiveMetric.stressBalance.value(_:)` rather than deriving
    /// it a second time, so the typed field below and the `mean`/`sd`
    /// dictionary entry under `"stress_balance"` cannot drift apart — the live
    /// path reads the dictionary, and a rollup whose two halves disagreed
    /// would be silently worse than either alone.
    static func stressBalance(_ pt: MetricsHistoryPoint) -> Double? {
        LiveMetric.stressBalance.value(pt).map(Double.init)
    }
}
