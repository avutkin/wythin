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

    private static let kox2014 = PracticeEvidence(
        doi: "10.1073/pnas.1322174111",
        title: "Voluntary activation of the sympathetic nervous system and attenuation of the innate immune response in humans",
        authors: "Kox et al.", journal: "PNAS", year: 2014,
        finding: "Trained volunteers using cyclic breathing with breath retention raised their own adrenaline and blunted the inflammatory response to an injected endotoxin — the clearest demonstration that a breathing practice can reach systems long assumed involuntary. The training also included cold exposure and meditation, so the holds cannot be credited alone.",
        mark: "PNA", tint: "#38BDF8")

    private static let elia2021 = PracticeEvidence(
        doi: "10.1007/s00421-021-04664-x",
        title: "Physiology, pathophysiology and (mal)adaptations to chronic apnoeic training: a state-of-the-art review",
        authors: "Elia et al.", journal: "European Journal of Applied Physiology", year: 2021,
        finding: "Reviews what repeated breath-hold training does: larger spleen volume, more myoglobin, better tolerance of a rising CO2. It also flags open questions on cognitive, renal and bone health in career divers — worth reading before treating long holds as free.",
        mark: "EJA", tint: "#F59E0B")

    private static let persson2023 = PracticeEvidence(
        doi: "10.3389/fphys.2023.1109958",
        title: "Splenic contraction and cardiovascular responses are augmented during apnea compared to rebreathing in humans",
        authors: "Persson et al.", journal: "Frontiers in Physiology", year: 2023,
        finding: "Holding the breath produced a stronger spleen contraction and a stronger cardiovascular diving response than breathing a stale gas mix — so it is the apnoea itself doing the work, not merely the falling oxygen.",
        mark: "FIP", tint: "#10B981")

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
            id: "resonance-breathing", title: "Resonance Breathing", subtitle: "Even in, even out, set in seconds",
            category: .breathwork, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Resonance",
            defaultDurationMins: 10, defaultBPM: EvenCadence.resonance.bpm,
            description: "An even breath in and out with nothing held at either end, at the classic five-and-a-half-second cadence — about five and a half breaths a minute. Set the pace in seconds a side, anywhere from three to eight, in halves. The ring shows the whole cycle and the beat keeps you on it.",
            howItWorks: [
                "Between about five and six seconds each way, the breath falls into step with the baroreflex — the loop that corrects blood pressure beat to beat — and heart rate swings furthest with each breath.",
                "That is the point of the pace rather than a side effect: the rate that maximises the swing is the same one that raises vagally-mediated heart rate variability. It is why this band has a name at all.",
                "Nothing is held at either end, so the breath stays even and unforced, which is what makes ten or twenty minutes of it sustainable.",
            ],
            evidence: [you2021, laborde2022, zaccaro2018],
            tags: ["Coherence", "Vagal Tone", "Calm"],
            art: practiceArt,
            // Declared as the cadence expresses it: 11 beats at 120 BPM is
            // exactly 5.5 s a phase, and whole beats are what keep the accent on
            // the phase change.
            kind: .pacer(EvenCadence.resonance.pattern)),

        Practice(
            id: "coherent-breathing", title: "Coherent Breathing", subtitle: "Counted in clicks, at a tempo you set",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Coherent Breathing",
            defaultDurationMins: 12, defaultBPM: 120,
            description: "The same even breath as Resonance, worked the other way round: you set how many metronome clicks each phase gets and how fast they run, and the seconds fall out of that. It opens on eleven clicks at 120 BPM — five and a half seconds a side, about five and a half breaths a minute. Counting the clicks is the practice; the pace is what you tune.",
            howItWorks: [
                "At around five and a half seconds each way the breath sits in the band where heart and blood-pressure control lock together, and heart rate variability reaches its widest swing.",
                "Counting clicks rather than watching a clock gives attention something concrete to hold. The accented click opens each phase, so the change of direction is heard rather than read.",
                "Tempo and count are separate on purpose: the same five and a half seconds can run as eleven quick clicks or as a slower, sparser count, and which one holds your attention is personal.",
                "On the honest side of the ledger: the physiological effect is well evidenced, and better decisions after slow breathing have been measured directly. Creative output specifically has not — the link there rests on correlations between heart rate variability and divergent thinking, not on trials. Treat the creative framing as the reason to try it, not as a finding.",
            ],
            evidence: [decouck2019, laborde2022, zaccaro2018],
            tags: ["Coherence", "Loose Attention", "Ideas"],
            art: practiceArt,
            // 11 clicks at 120 BPM is exactly 5.5 s a phase. Whole beats are what
            // keep the accent on the phase change at any tempo.
            kind: .pacer(.even(beats: 11)),
            paceControl: .beatsAndTempo),

        Practice(
            id: "hold-breath", title: "Hold Breath", subtitle: "Holds on empty, in sets",
            category: .breathwork, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Breath Hold",
            defaultDurationMins: 5, defaultBPM: 60,
            description: "Two paced breaths, then hold with your lungs empty, then do it again. You set the hold and the number of sets; the session counts you in with a rising tone, marks each hold with a beep either end, and shows the clock so you never have to. Sit or lie down on land — never in or near water.",
            howItWorks: [
                "Holding on empty lets carbon dioxide climb faster than a hold on full would. The urge to breathe is a response to that CO2, not to running out of oxygen, so this trains the tolerance rather than the supply.",
                "A hold also triggers the diving response — the heart slows and the spleen squeezes a reserve of red cells into circulation. Repeating it is the stimulus the adaptations are built on.",
                "The point is the recovery, not the heroics. What you are practising is meeting an uncomfortable signal without panicking and then returning to a normal breath, which is the same move under any other kind of load.",
                "Honest limits: the training adaptations come from divers holding far longer than this, and the review below raises open questions about very heavy long-term practice. Short sets are where the risk-to-benefit sits well.",
            ],
            evidence: [persson2023, elia2021, kox2014],
            tags: ["CO2 Tolerance", "Diving Response", "Composure"],
            art: practiceArt,
            kind: .holdTrainer(.standard)),
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
