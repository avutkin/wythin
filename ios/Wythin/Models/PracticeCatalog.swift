import Foundation

// MARK: - PracticeCatalog
//
// Seed content for the Practices hub. Trimmed to the two guided pacers while
// they are built out; the browsable content practices (the meditations, the
// movement work) are in git history at b84a5cb and come back once these settle.

enum PracticeCatalog {

    static let practices: [Practice] = [
        Practice(
            id: "box-breathing", title: "Box Breathing", subtitle: "Even in, even held, even out, even held",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Box Breathing", defaultDurationMins: 6,
            description: "An even four-part breath used by people who need to stay level under load. A metronome counts each beat so you can keep the rhythm with your eyes closed, and the box on screen shows exactly where you are in the cycle. Set the time, pace and tempo at the bottom of the session.",
            tags: ["Steady", "Control", "Clarity"],
            // Sampled from the reference image: a field of green running to olive.
            // A stand-in for the grainy texture asset, which the two-stop gradient
            // in PracticeArt can't reproduce.
            art: PracticeArt(hexStops: ["#4E7A3E", "#94903F"]),
            kind: .pacer(.box)),

        Practice(
            id: "resonance-breathing", title: "Resonance Breathing", subtitle: "Six breaths a minute, no holds",
            category: .breathwork, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Resonance", defaultDurationMins: 10,
            description: "An even breath in and out with nothing held at either end. At the default pace it lands near six breaths a minute — the rate around which heart-rate variability peaks and heart and breath fall into step. The ring shows the whole cycle; the beat keeps you on it.",
            tags: ["Coherence", "Vagal Tone", "Calm"],
            art: PracticeArt(hexStops: ["#00E5A0", "#134E4A"]),
            kind: .pacer(.resonance)),
    ]

    // MARK: Lookups

    static func practices(in category: PracticeCategory) -> [Practice] {
        practices.filter { $0.category == category }
    }

    /// Practices serving a state, with the ones that exist *for* it first and the
    /// ones it merely borrows behind. Ties keep catalog order, so the ordering is
    /// stable without a second sort key.
    static func practices(for state: PracticeState) -> [Practice] {
        practices
            .filter { $0.states.contains(state) }
            .enumerated()
            .sorted { lhs, rhs in
                let lp = lhs.element.primaryState == state
                let rp = rhs.element.primaryState == state
                return lp == rp ? lhs.offset < rhs.offset : lp
            }
            .map(\.element)
    }

    static var starred: [Practice] {
        practices.filter(\.isStarred)
    }
}
