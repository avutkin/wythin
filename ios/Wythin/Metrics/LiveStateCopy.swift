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
        case .renewed_thriving:     options = ["Fully Charged", "Wide Open", "Thriving"]
        case .stable_neutral:       options = ["Steady", "Level", "Even Keel"]
        case .recovering_resetting: options = ["Coming Back", "Refilling", "On The Mend"]
        case .depleted_numb:        options = ["Running Flat", "Low Ebb", "Running On Empty"]
        case .stressed_activated:   options = ["Wired", "Revved Up", "Running Hot"]
        case .overloaded_exhausted: options = ["Stretched Thin", "Overloaded", "Past Full"]
        case .shutdown_burnout:     options = ["Shut Down", "Running On Fumes", "Bottomed Out"]
        }

        let dayNumber = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        let stateOffset = LiveStateKey.allCases.firstIndex(of: key) ?? 0
        return options[(dayNumber + stateOffset) % options.count]
    }

    static func feeling(for key: LiveStateKey) -> String {
        switch key {
        case .engaged_performing:   return "sharp and steady — you can push"
        case .calm_alert:           return "clear and unhurried — easy to think"
        case .renewed_thriving:     return "rested and wide awake"
        case .stable_neutral:       return "nothing pulling either way"
        case .recovering_resetting: return "low but mending — the tank is refilling"
        case .depleted_numb:        return "flat and far away — motivation is thin"
        case .stressed_activated:   return "revved up and hard to settle"
        case .overloaded_exhausted: return "stretched thin — everything costs more"
        case .shutdown_burnout:     return "running on empty — this one needs real rest"
        }
    }
}
