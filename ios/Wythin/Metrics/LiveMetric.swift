import Foundation

/// The metrics the live state reads, in one place.
///
/// `DailyRollup`, `LiveBaseline` and `LiveStateClassifier` all key off this, so
/// a metric cannot be summarised under one name and scored under another.
/// `rawValue` is the wire key shared with the server payload.
enum LiveMetric: String, CaseIterable {
    case hr         = "hr"
    case rmssd      = "rmssd"
    case rsa        = "rsa"
    case sdnn       = "sdnn"
    case lfHF       = "lf_hf"
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
        case .lfHF:      return "stress balance"
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

    func value(_ p: MetricsHistoryPoint) -> Float? {
        switch self {
        case .hr:        return p.meanBPM
        case .rmssd:     return p.rmssd
        case .rsa:       return p.rsaMs
        case .sdnn:      return p.sdnn
        case .lfHF:      return p.lfHF
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
