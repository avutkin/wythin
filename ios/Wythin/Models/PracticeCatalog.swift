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

    static let practices: [Practice] = [
        // ── Featured biofeedback ──────────────────────────────────────────
        Practice(
            id: "resonance", title: "Resonance", subtitle: "Find your coherent breath",
            teacherID: "mara-quinn", category: .recovery, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Resonance", defaultDurationMins: 10,
            description: "A guided pacer that walks your breath toward ~6 breaths a minute — the rhythm where heart-rate variability peaks. Live coherence, breath rate and RSA show you when you've found the groove.",
            tags: ["Coherence", "Vagal Tone", "Calm"],
            art: PracticeArt(symbol: "sparkles", hexStops: ["#00E5A0", "#134E4A"]),
            kind: .biofeedback(.resonance)),

        // ── Breathwork ────────────────────────────────────────────────────
        Practice(
            id: "box-breathing", title: "Box Breathing", subtitle: "Six in, six held, six out, six held",
            teacherID: "mara-quinn", category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Box Breathing", defaultDurationMins: 6,
            description: "An even four-part breath used by people who need to stay level under load. A metronome counts each second so you can keep the rhythm with your eyes closed, and the box on screen shows exactly where you are in the cycle. 60 beats a minute, six to a side.",
            tags: ["Steady", "Control", "Clarity"],
            art: PracticeArt(symbol: "square.dashed", hexStops: ["#60A5FA", "#1E293B"]),
            kind: .pacer(.box)),
        Practice(
            id: "coherent-calm", title: "Coherent Calm", subtitle: "Even in, even out",
            teacherID: "mara-quinn", category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Coherent Breathing", defaultDurationMins: 8,
            description: "A simple equal-ratio breath to down-shift the stress response and steady your focus in a few minutes.",
            tags: ["Focus", "Down-regulate"],
            art: PracticeArt(symbol: "wind", hexStops: ["#58A6FF", "#1E3A5F"]),
            kind: .content),
        Practice(
            id: "physiological-sigh", title: "Physiological Sigh", subtitle: "Two in, one long out",
            teacherID: "mara-quinn", category: .breathwork, states: [.anxiety, .stress],
            activityType: .breathwork, subtype: "Pranayama", defaultDurationMins: 3,
            description: "A double inhale through the nose followed by a long, slow exhale — the fastest way the body has to take an edge off in real time. Three minutes is usually enough.",
            tags: ["Fast Relief", "Reset"],
            art: PracticeArt(symbol: "aqi.medium", hexStops: ["#7DD3FC", "#0C4A6E"]),
            kind: .content),
        Practice(
            id: "wind-down-breath", title: "Wind-Down Breath", subtitle: "4-7-8 before sleep",
            teacherID: "mara-quinn", category: .recovery, states: [.sleep, .anxiety],
            activityType: .breathwork, subtype: "4-7-8", defaultDurationMins: 6,
            description: "A longer-exhale pattern to release the day and prime your body for rest.",
            tags: ["Sleep", "Relax"],
            art: PracticeArt(symbol: "moon.stars", hexStops: ["#A78BFA", "#312E81"]),
            kind: .content),

        // ── Meditation ────────────────────────────────────────────────────
        Practice(
            id: "body-scan", title: "Body Scan", subtitle: "Settle into the body",
            teacherID: "elias-vance", category: .meditation, states: [.anxiety, .sleep],
            activityType: .meditation, subtype: "Body Scan", defaultDurationMins: 15,
            description: "Move attention slowly through the body, softening what's held and returning to the present.",
            tags: ["Grounding", "Awareness"],
            art: PracticeArt(symbol: "figure.mind.and.body", hexStops: ["#818CF8", "#312E81"]),
            kind: .content),
        Practice(
            id: "morning-stillness", title: "Morning Stillness", subtitle: "Begin with clarity",
            teacherID: "elias-vance", category: .meditation, states: [.focus],
            activityType: .meditation, subtype: "Guided", defaultDurationMins: 10,
            description: "A short guided sit to clear mental clutter and set a steady tone for the day.",
            tags: ["Morning", "Clarity"],
            art: PracticeArt(symbol: "sunrise", hexStops: ["#FCD34D", "#78350F"]),
            kind: .content),
        Practice(
            id: "focus-reset", title: "Focus Reset", subtitle: "Clear the desk in five minutes",
            teacherID: "elias-vance", category: .meditation, states: [.focus],
            activityType: .meditation, subtype: "Open Awareness", defaultDurationMins: 5,
            description: "A short open-awareness sit for the gap between tasks. Let whatever the last hour left behind settle, so the next hour starts from a clean surface.",
            tags: ["Reset", "Between Tasks"],
            art: PracticeArt(symbol: "arrow.trianglehead.counterclockwise", hexStops: ["#38BDF8", "#0C4A6E"]),
            kind: .content),
        Practice(
            id: "loving-kindness", title: "Loving-Kindness", subtitle: "Warmth toward yourself",
            teacherID: "elias-vance", category: .meditation, states: [.anxiety],
            activityType: .meditation, subtype: "Loving-Kindness", defaultDurationMins: 12,
            description: "Offer simple phrases of goodwill — to yourself and outward — to soften a busy or critical mind.",
            tags: ["Compassion", "Heart"],
            art: PracticeArt(symbol: "heart", hexStops: ["#F9A8D4", "#831843"]),
            kind: .content),
        Practice(
            id: "grounding-54321", title: "Grounding 5-4-3-2-1", subtitle: "Back into the room",
            teacherID: "elias-vance", category: .meditation, states: [.anxiety],
            activityType: .meditation, subtype: "Guided", defaultDurationMins: 5,
            description: "Name five things you can see, four you can touch, three you can hear, two you can smell, one you can taste. A sensory ladder out of a spiralling head and back into the room you're actually in.",
            tags: ["Grounding", "Senses"],
            art: PracticeArt(symbol: "hand.raised.fingers.spread", hexStops: ["#C4B5FD", "#4C1D95"]),
            kind: .content),
        Practice(
            id: "yoga-nidra", title: "Yoga Nidra", subtitle: "Sleep without sleeping",
            teacherID: "elias-vance", category: .recovery, states: [.sleep],
            activityType: .meditation, subtype: "Yoga Nidra", defaultDurationMins: 25,
            description: "A long, guided lie-down that walks the body through stages of rest. Follow it to the end or drift off partway — either counts.",
            tags: ["Deep Rest", "Night"],
            art: PracticeArt(symbol: "bed.double", hexStops: ["#8B5CF6", "#2E1065"]),
            kind: .content),

        // ── Movement ──────────────────────────────────────────────────────
        Practice(
            id: "grounding-flow", title: "Grounding Flow", subtitle: "Slow, breath-led yoga",
            teacherID: "noor-haddad", category: .movement, states: [.stress, .anxiety],
            activityType: .exercise, subtype: "Yoga", defaultDurationMins: 20,
            description: "A gentle flow that links movement to breath, releasing the hips, spine and shoulders.",
            tags: ["Mobility", "Flexibility"],
            art: PracticeArt(symbol: "figure.yoga", hexStops: ["#34D399", "#065F46"]),
            kind: .content),
        Practice(
            id: "slow-mobility", title: "Slow Mobility", subtitle: "Open and reset",
            teacherID: "noor-haddad", category: .movement, states: [.stress, .sleep],
            activityType: .exercise, subtype: "Stretching", defaultDurationMins: 15,
            description: "Unhurried mobility work to undo the stiffness of sitting and move more freely.",
            tags: ["Recovery", "Range"],
            art: PracticeArt(symbol: "figure.flexibility", hexStops: ["#6EE7B7", "#065F46"]),
            kind: .content),
        Practice(
            id: "walking-focus", title: "Walking Focus", subtitle: "Think it through on your feet",
            teacherID: "noor-haddad", category: .movement, states: [.focus],
            activityType: .exercise, subtype: "Nature Walk", defaultDurationMins: 20,
            description: "An unhurried walk with no podcast and no phone. Easy movement and a moving horizon do more for a stuck problem than another hour at the desk.",
            tags: ["Clarity", "Outdoors"],
            art: PracticeArt(symbol: "figure.walk.motion", hexStops: ["#4ADE80", "#14532D"]),
            kind: .content),
        Practice(
            id: "evening-unwind", title: "Evening Unwind", subtitle: "Put the day down",
            teacherID: "noor-haddad", category: .recovery, states: [.sleep],
            activityType: .exercise, subtype: "Stretching", defaultDurationMins: 12,
            description: "Floor-based stretching for the hips, hamstrings and neck, paced slowly enough that your breath keeps lengthening. Best done in the last hour before bed.",
            tags: ["Night", "Release"],
            art: PracticeArt(symbol: "figure.cooldown", hexStops: ["#818CF8", "#1E1B4B"]),
            kind: .content),

        // ── Movement · biofeedback workouts ───────────────────────────────
        Practice(
            id: "strength-set", title: "Strength Set", subtitle: "Lift with live feedback",
            teacherID: "theo-brandt", category: .movement, states: [.stress],
            activityType: .exercise, subtype: "Power Lifting", defaultDurationMins: 30,
            description: "Run a strength session with live autonomic balance and heart-rate recovery so you can gauge effort and rest between sets.",
            tags: ["Strength", "Biofeedback"],
            art: PracticeArt(symbol: "figure.strengthtraining.traditional", hexStops: ["#FB7185", "#7F1D1D"]),
            kind: .biofeedback(.workout)),
        Practice(
            id: "zone-2-run", title: "Zone 2 Run", subtitle: "Easy aerobic pace",
            teacherID: "theo-brandt", category: .movement, states: [.stress, .focus],
            activityType: .exercise, subtype: "Easy Run", defaultDurationMins: 30,
            description: "Keep it conversational. Live HR and recovery help you hold an easy aerobic zone and build a base.",
            tags: ["Endurance", "Biofeedback"],
            art: PracticeArt(symbol: "figure.run", hexStops: ["#F97316", "#7C2D12"]),
            kind: .biofeedback(.workout)),
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
