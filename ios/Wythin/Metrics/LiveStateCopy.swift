import Foundation

/// The words for a state, written on-device.
///
/// This is why the collapsed line needs no network: the name and the feeling
/// are local, and only the data-specific half of the sentence waits on
/// narration.
///
/// Variation is deterministic, keyed on the day. Randomising would reword the
/// title on every view re-render, which reads as instability rather than
/// freshness.
///
/// Uses exhaustive switch statements (no default clause) so adding a
/// `LiveStateKey` case forces this file to compile-fail until its copy is
/// provided.
enum LiveStateCopy {

    static func title(for key: LiveStateKey, on day: Date = .now) -> String {
        let options: [String]
        switch key {
        case .engaged_performing:   options = ["Locked In", "In The Zone", "Firing Well"]
        case .calm_alert:           options = ["Clear And Calm", "Quietly Sharp", "Settled"]
        case .renewed_thriving:     options = ["Fully Charged", "Wide Open", "Brimming"]
        case .stable_neutral:       options = ["Steady", "Level", "Even Keel"]
        case .recovering_resetting: options = ["Coming Back", "Refilling", "On The Mend"]
        case .depleted_numb:        options = ["Running Light", "Low Ebb", "Quiet Tank"]
        case .stressed_activated:   options = ["Wound Up", "Running Hot", "Revved Up"]
        case .overloaded_exhausted: options = ["Carrying A Lot", "Stretched Thin", "Past Full"]
        case .shutdown_burnout:     options = ["Running On Empty", "Deeply Tired", "Worn Through"]
        }

        let dayNumber = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        let stateOffset = LiveStateKey.allCases.firstIndex(of: key) ?? 0
        return options[(dayNumber + stateOffset) % options.count]
    }

    /// Deliberately gentlest exactly where the reading is worst: a person
    /// whose body is telling them they are depleted should not also be told
    /// they are broken. Each clause names the moment, not a deficit in the
    /// person, and for the harder states acknowledges it before pointing
    /// anywhere. The reading itself is never softened — only how it's said.
    static func feeling(for key: LiveStateKey) -> String {
        switch key {
        case .engaged_performing:   return "sharp and steady, ready to push"
        case .calm_alert:           return "easy to think right now"
        case .renewed_thriving:     return "rested and wide awake"
        case .stable_neutral:       return "nothing pulling either way"
        case .recovering_resetting: return "quietly rebuilding, and that is the work"
        case .depleted_numb:        return "not much in the tank today, so go gently"
        case .stressed_activated:   return "hard to settle right now, and that is worth easing"
        case .overloaded_exhausted: return "everything costs more right now, which is fair"
        case .shutdown_burnout:     return "this one asks for real rest, not effort"
        }
    }
}
