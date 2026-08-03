import Foundation

/// The words for a state, written on-device.
///
/// This is why the collapsed line needs no network: the name and the feeling
/// are local, and only the data-specific half of the sentence waits on
/// narration. Follows the `NudgeCopy` pattern.
///
/// Variation is deterministic, keyed on the day. Randomising would reword the
/// title on every view re-render, which reads as instability rather than
/// freshness.
enum LiveStateCopy {

    private static let titles: [LiveStateKey: [String]] = [
        .engaged_performing:   ["Locked In", "In The Zone", "Firing Well"],
        .calm_alert:           ["Clear And Calm", "Quietly Sharp", "Settled"],
        .renewed_thriving:     ["Fully Charged", "Wide Open", "Thriving"],
        .stable_neutral:       ["Steady", "Level", "Even Keel"],
        .recovering_resetting: ["Coming Back", "Refilling", "On The Mend"],
        .depleted_numb:        ["Running Flat", "Low Ebb", "Running On Empty"],
        .stressed_activated:   ["Wired", "Revved Up", "Running Hot"],
        .overloaded_exhausted: ["Stretched Thin", "Overloaded", "Past Full"],
        .shutdown_burnout:     ["Shut Down", "Running On Fumes", "Bottomed Out"]
    ]

    private static let feelings: [LiveStateKey: String] = [
        .engaged_performing:   "sharp and steady — you can push",
        .calm_alert:           "clear and unhurried — easy to think",
        .renewed_thriving:     "rested and wide awake",
        .stable_neutral:       "nothing pulling either way",
        .recovering_resetting: "low but mending — the tank is refilling",
        .depleted_numb:        "flat and far away — motivation is thin",
        .stressed_activated:   "revved up and hard to settle",
        .overloaded_exhausted: "stretched thin — everything costs more",
        .shutdown_burnout:     "running on empty — this one needs real rest"
    ]

    static func title(for key: LiveStateKey, on day: Date = .now) -> String {
        let options = titles[key] ?? ["Reading"]
        let dayNumber = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        let stateOffset = LiveStateKey.allCases.firstIndex(of: key) ?? 0
        return options[(dayNumber + stateOffset) % options.count]
    }

    static func feeling(for key: LiveStateKey) -> String {
        feelings[key] ?? "still reading"
    }
}
