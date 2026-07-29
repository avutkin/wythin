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

    var id: Date { day }
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
            wearSeconds:   Double(valid.count) * tickSeconds
        )
    }

    /// Stress Balance is the breathing-robust 0–100 arousal dial, not a raw
    /// LF/HF ratio — there is no stored field for it, so it is derived per
    /// tick exactly as `ActivityMetricsGrid.swift:58` does, then averaged.
    static func stressBalance(_ pt: MetricsHistoryPoint) -> Double? {
        AutonomicCompute.balance(rmssd: pt.rmssd, lf: pt.lfPower, hf: pt.hfPower,
                                 breathBPM: pt.breathBPM, meanBPM: pt.meanBPM,
                                 baselineRmssd: nil)
            .map { Double($0.sns) * 100 }
    }
}
