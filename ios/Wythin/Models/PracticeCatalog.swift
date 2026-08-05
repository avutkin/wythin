import Foundation

// MARK: - PracticeCatalog
//
// Seed content for the Practices hub. All teachers and practices here are
// original placeholders (fictional names, original copy) so the hub is
// browsable and testable before any real content pipeline exists.

enum PracticeCatalog {

    static let teachers: [Teacher] = [
        Teacher(id: "mara-quinn",  name: "Mara Quinn",  title: "Breathwork Guide",
                bio: "Mara teaches slow, paced breathing to steady the nervous system and build calm you can return to any time.",
                art: PracticeArt(symbol: "lungs", hexStops: ["#58A6FF", "#1E3A5F"])),
        Teacher(id: "elias-vance", name: "Elias Vance", title: "Meditation Teacher",
                bio: "Elias offers quiet, unforced meditations — space to notice the mind and let it settle.",
                art: PracticeArt(symbol: "brain.head.profile", hexStops: ["#818CF8", "#312E81"])),
        Teacher(id: "noor-haddad", name: "Noor Haddad", title: "Movement Coach",
                bio: "Noor blends mobility and mindful movement to release tension and reconnect body and breath.",
                art: PracticeArt(symbol: "figure.yoga", hexStops: ["#34D399", "#065F46"])),
        Teacher(id: "theo-brandt", name: "Theo Brandt", title: "Strength & Endurance",
                bio: "Theo coaches strength and easy-pace endurance work, with live biofeedback to keep effort honest.",
                art: PracticeArt(symbol: "figure.strengthtraining.traditional", hexStops: ["#FB7185", "#7F1D1D"])),
    ]

    // Trimmed to Box Breathing while the pacer is being built out. The rest of
    // the catalog (Resonance, the meditations, the movement practices) is in git
    // history at b84a5cb and comes back once the pacer settles.
    static let practices: [Practice] = [
        Practice(
            id: "box-breathing", title: "Box Breathing", subtitle: "Even in, even held, even out, even held",
            teacherID: "mara-quinn", category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Box Breathing", defaultDurationMins: 6,
            description: "An even four-part breath used by people who need to stay level under load. A metronome counts each beat so you can keep the rhythm with your eyes closed, and the box on screen shows exactly where you are in the cycle. Set the time, pace and tempo at the bottom of the session.",
            tags: ["Steady", "Control", "Clarity"],
            // Sampled from the reference image: a field of green running to olive.
            // A stand-in for the grainy texture asset, which the two-stop gradient
            // in PracticeArt can't reproduce.
            art: PracticeArt(hexStops: ["#4E7A3E", "#94903F"]),
            kind: .pacer(.box)),
    ]

    // MARK: Lookups

    static func teacher(_ id: String) -> Teacher? {
        teachers.first { $0.id == id }
    }

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

    static func practices(byTeacher id: String) -> [Practice] {
        practices.filter { $0.teacherID == id }
    }

    static var starred: [Practice] {
        practices.filter(\.isStarred)
    }
}
