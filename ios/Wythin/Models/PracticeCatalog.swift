import Foundation

// MARK: - PracticeCatalog
//
// Seed content for the Practices hub. Trimmed to the two guided pacers while
// they are built out; the browsable content practices (the meditations, the
// movement work) are in git history at b84a5cb and come back once these settle.

enum PracticeCatalog {

    // MARK: Studies
    //
    // Transcribed from the papers themselves, checked against PubMed / the
    // publisher. `finding` says what each study actually reported — including
    // where the result is weaker than the practice's marketing would like.

    private static let balban2023 = PracticeEvidence(
        doi: "10.1016/j.xcrm.2022.100895",
        title: "Brief structured respiration practices enhance mood and reduce physiological arousal",
        authors: "Balban et al.", journal: "Cell Reports Medicine", year: 2023,
        finding: "A month-long randomised trial of three breathwork practices against mindfulness. Box breathing improved mood and lowered anxiety — though exhale-focused breathing improved mood more.",
        mark: "CRM", tint: "#E11D48")

    private static let zaccaro2018 = PracticeEvidence(
        doi: "10.3389/fnhum.2018.00353",
        title: "How breath-control can change your life: a systematic review on psycho-physiological correlates of slow breathing",
        authors: "Zaccaro et al.", journal: "Frontiers in Human Neuroscience", year: 2018,
        finding: "Across the literature, breathing under about ten a minute shifts autonomic balance toward the parasympathetic side and is associated with reduced anxiety.",
        mark: "FHN", tint: "#3B82F6")

    private static let laborde2022 = PracticeEvidence(
        doi: "10.1016/j.neubiorev.2022.104711",
        title: "Effects of voluntary slow breathing on heart rate and heart rate variability: a systematic review and a meta-analysis",
        authors: "Laborde et al.", journal: "Neuroscience & Biobehavioral Reviews", year: 2022,
        finding: "Pooling the trials, deliberately slowing the breath raises vagally-mediated heart rate variability — during the practice and afterwards.",
        mark: "NBR", tint: "#F59E0B")

    private static let decouck2019 = PracticeEvidence(
        doi: "10.1016/j.ijpsycho.2019.02.011",
        title: "How breathing can help you make better decisions: two studies on the effects of breathing patterns on heart rate variability and decision-making in business cases",
        authors: "De Couck et al.", journal: "Int. Journal of Psychophysiology", year: 2019,
        finding: "Deep, slow breathing before a business-case task raised heart rate variability and produced markedly more correct answers than normal breathing. The task measured decision quality, not creativity.",
        mark: "IJP", tint: "#8B5CF6")

    private static let you2021 = PracticeEvidence(
        doi: "10.3390/ijerph182312478",
        title: "Single slow-paced breathing session at six cycles per minute: investigation of dose-response relationship on cardiac vagal activity",
        authors: "You et al.", journal: "Int. Journal of Environmental Research and Public Health", year: 2021,
        finding: "Six breaths a minute raised cardiac vagal activity at every session length tested, from five minutes up — but longer sessions left the resting breathing rate lower afterwards.",
        mark: "IJE", tint: "#10B981")

    /// One art token across the catalog, sampled from the reference image: a
    /// field of green running to olive. A stand-in for the grainy texture asset,
    /// which the two-stop gradient in PracticeArt can't reproduce.
    private static let practiceArt = PracticeArt(hexStops: ["#4E7A3E", "#94903F"])

    static let practices: [Practice] = [
        Practice(
            id: "box-breathing", title: "Box Breathing", subtitle: "Even in, even held, even out, even held",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Box Breathing",
            defaultDurationMins: 6, defaultBPM: 60,
            description: "An even four-part breath used by people who need to stay level under load. A metronome counts each beat so you can keep the rhythm with your eyes closed, and the box on screen shows exactly where you are in the cycle. Set the time, pace and tempo at the bottom of the session.",
            howItWorks: [
                "Holding the count near a handful of breaths a minute tips the autonomic balance toward the parasympathetic side: heart rate variability rises and physical arousal drops.",
                "The two holds make the rhythm countable. Attention gets something concrete to return to, which is easier than being told to stop thinking.",
                "It works on the session, not on the month — vagal activity rises while you are doing it, so a few minutes is a real intervention rather than a down payment.",
            ],
            evidence: [balban2023, zaccaro2018, laborde2022],
            tags: ["Steady", "Control", "Clarity"],
            art: practiceArt,
            kind: .pacer(.box)),

        Practice(
            id: "resonance-breathing", title: "Resonance Breathing", subtitle: "Six breaths a minute, no holds",
            category: .breathwork, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Resonance",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "An even breath in and out with nothing held at either end. At the default pace it lands near six breaths a minute — the rate around which heart-rate variability peaks and heart and breath fall into step. The ring shows the whole cycle; the beat keeps you on it.",
            howItWorks: [
                "Around six breaths a minute the breath falls into step with the baroreflex — the loop that corrects blood pressure beat to beat — and heart rate swings furthest with each breath.",
                "That is the point of the pace rather than a side effect: the same rate that maximises the swing is the one that raises vagally-mediated heart rate variability.",
                "Nothing is held at either end, so the breath stays even and unforced, which is what makes ten or twenty minutes of it sustainable.",
            ],
            evidence: [you2021, laborde2022, zaccaro2018],
            tags: ["Coherence", "Vagal Tone", "Calm"],
            art: practiceArt,
            kind: .pacer(.resonance)),

        Practice(
            id: "coherent-breathing", title: "Coherent Breathing", subtitle: "Five and a half seconds each way",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Coherent Breathing",
            defaultDurationMins: 12, defaultBPM: 120,
            description: "The classic 5.5-second cadence: five and a half seconds in, five and a half out, nothing held. That works out at about five and a half breaths a minute — slow enough to settle you, even enough that you stop having to think about it. Good for the loose, unhurried attention that ideas tend to arrive in.",
            howItWorks: [
                "At five and a half seconds each way the breath sits in the band where heart and blood-pressure control lock together, and heart rate variability reaches its widest swing.",
                "The state that produces is calm but awake — the body settling without the mind going dull, which is the condition most people describe thinking loosely in.",
                "On the honest side of the ledger: the physiological effect is well evidenced, and better decisions after slow breathing have been measured directly. Creative output specifically has not — the link there rests on correlations between heart rate variability and divergent thinking, not on trials. Treat the creative framing as the reason to try it, not as a finding.",
            ],
            evidence: [decouck2019, laborde2022, zaccaro2018],
            tags: ["Coherence", "Loose Attention", "Ideas"],
            art: practiceArt,
            // 11 beats at 120 BPM is exactly 5.5 s a phase. Pace is counted in
            // whole beats so the accent can never drift off the phase change,
            // and 5.5 s is only reachable on a half-second beat.
            kind: .pacer(.even(beats: 11))),
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
