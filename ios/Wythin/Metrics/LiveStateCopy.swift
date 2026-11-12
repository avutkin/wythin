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
        case .engaged_performing:   options = [LocalizedCopy.text("Locked In"), LocalizedCopy.text("In The Zone"), LocalizedCopy.text("Firing Well")]
        case .calm_alert:           options = [LocalizedCopy.text("Clear And Calm"), LocalizedCopy.text("Quietly Sharp"), LocalizedCopy.text("Settled")]
        case .renewed_thriving:     options = [LocalizedCopy.text("Fully Charged"), LocalizedCopy.text("Wide Open"), LocalizedCopy.text("Brimming")]
        case .stable_neutral:       options = [LocalizedCopy.text("Steady"), LocalizedCopy.text("Level"), LocalizedCopy.text("Even Keel")]
        case .recovering_resetting: options = [LocalizedCopy.text("Coming Back"), LocalizedCopy.text("Refilling"), LocalizedCopy.text("On The Mend")]
        case .depleted_numb:        options = [LocalizedCopy.text("Running Light"), LocalizedCopy.text("Low Ebb"), LocalizedCopy.text("Quiet Tank")]
        case .stressed_activated:   options = [LocalizedCopy.text("Wound Up"), LocalizedCopy.text("Running Hot"), LocalizedCopy.text("Revved Up")]
        case .overloaded_exhausted: options = [LocalizedCopy.text("Carrying A Lot"), LocalizedCopy.text("Stretched Thin"), LocalizedCopy.text("Past Full")]
        case .shutdown_burnout:     options = [LocalizedCopy.text("Running On Empty"), LocalizedCopy.text("Deeply Tired"), LocalizedCopy.text("Worn Through")]
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
        case .engaged_performing:   return LocalizedCopy.text("sharp and steady, ready to push")
        case .calm_alert:           return LocalizedCopy.text("easy to think right now")
        case .renewed_thriving:     return LocalizedCopy.text("rested and wide awake")
        case .stable_neutral:       return LocalizedCopy.text("nothing pulling either way")
        case .recovering_resetting: return LocalizedCopy.text("quietly rebuilding, and that is the work")
        case .depleted_numb:        return LocalizedCopy.text("not much in the tank today, so go gently")
        case .stressed_activated:   return LocalizedCopy.text("hard to settle right now, and that is worth easing")
        case .overloaded_exhausted: return LocalizedCopy.text("everything costs more right now, which is fair")
        case .shutdown_burnout:     return LocalizedCopy.text("this one asks for real rest, not effort")
        }
    }
}
