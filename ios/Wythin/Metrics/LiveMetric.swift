import Foundation

/// The metrics the live state reads, in one place.
///
/// `DailyRollup`, `LiveBaseline` and `LiveStateClassifier` all key off this, so
/// a metric cannot be summarised under one name and scored under another.
/// `rawValue` is the key `DailyRollup.mean`/`.sd` persist under, so changing one
/// requires a `TrackCache.rollupComputeVersion` bump.
///
/// NOTE: this is deliberately *not* the same list as
/// `LiveStateTrendCompute.keyPaths`, which is the server's `/insights` payload
/// contract and carries its own hardcoded strings. The two overlap by
/// convention only: `stress_balance` here is the breathing-robust SNS share,
/// the same quantity `TrackMetrics` sends under that key (see
/// `TrackMetricSpecTests.testTrendKeysAreUniqueAndStressBalanceIsNotLfHf`),
/// while the payload's `lf_hf` remains the raw ratio.
enum LiveMetric: String, CaseIterable {
    case hr         = "hr"
    case rmssd      = "rmssd"
    case rsa        = "rsa"
    case sdnn       = "sdnn"
    case stressBalance = "stress_balance"
    case coherence  = "coherence"
    case breathBPM  = "breath_bpm"
    case cbi        = "cbi"
    case pip        = "pip"
    case dfa1       = "dfa1"
    case dc         = "dc"
    case rcmse      = "rcmse"
    case vti        = "vti"

    /// Plain language only — this reaches the user.
    var displayName: String {
        switch self {
        case .hr:        return "heart rate"
        case .rmssd:     return "recovery"
        case .rsa:       return "breathing depth"
        case .sdnn:      return "overall variability"
        case .stressBalance: return "stress balance"
        case .coherence: return "rhythm"
        case .breathBPM: return "breathing"
        case .cbi:       return "body load"
        case .pip:       return "inner noise"
        case .dfa1:      return "focus"
        case .dc:        return "settling depth"
        case .rcmse:     return "adaptability"
        case .vti:       return "calm power"
        }
    }

    /// The metric's value at one tick.
    ///
    /// `stressBalance` is the only derived one: it is the breathing-robust SNS
    /// share (0–100), NOT `p.lfHF`. The raw ratio spikes during resonance
    /// breathing (~6/min) because the vagal peak moves out of HF into LF, so
    /// scoring it would read the most vagally-activating breathing there is as
    /// tension — the population-prior failure this whole engine exists to
    /// remove. `AutonomicCompute.balance` is RMSSD-driven and immune to that;
    /// see its doc, and `LiveView.stressBalance(_:)` which states the same
    /// position for the metric tile.
    func value(_ p: MetricsHistoryPoint) -> Float? {
        switch self {
        case .hr:        return p.meanBPM
        case .rmssd:     return p.rmssd
        case .rsa:       return p.rsaMs
        case .sdnn:      return p.sdnn
        case .stressBalance:
            return AutonomicCompute.balance(rmssd: p.rmssd, lf: p.lfPower, hf: p.hfPower,
                                            breathBPM: p.breathBPM, meanBPM: p.meanBPM,
                                            baselineRmssd: nil)
                .map { $0.sns * 100 }
        case .coherence: return p.coherence
        case .breathBPM: return p.breathBPM
        case .cbi:       return p.cbi
        case .pip:       return p.pip
        case .dfa1:      return p.dfa1
        case .dc:        return p.dc
        case .rcmse:     return p.rcmse
        case .vti:       return p.vti
        }
    }
}
