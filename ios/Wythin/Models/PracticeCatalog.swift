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
            id: "coherent-breathing-5x5", title: "Coherent Breathing 5×5", subtitle: "Five counts in, five out, eyes open",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Coherent Breathing",
            defaultDurationMins: 12, defaultBPM: 60,
            description: "Five counts in, five counts out, one count a second. An even breath with no weight on either side — and unlike most slow breathing, it is meant to sharpen rather than settle you. Do it with your eyes open, looking at something: keeping the visual field engaged is what keeps the session alert, and the same breath with the eyes closed drifts toward a wind-down. The tempo, what a count is worth, and each phase\'s count are all yours to set; the seconds fall out of the three.",
            howItWorks: [
                "Blood pressure and heart rate carry a slow oscillation at roughly a tenth of a hertz — the wave Ludwig Traube and Ewald Hering described in the 1860s, still called the Traube–Hering wave. Five seconds each way is a ten-second cycle, which is exactly a tenth of a hertz, so this breath lands on that wave rather than beside it.",
                "Equal counts give the in-breath as much room as the out-breath. Heart rate climbs through each inhale as the vagal brake eases and falls through each exhale as it comes back on, so the swing is large and symmetrical — the rousing half and the calming half in equal measure. That balance is what the sharpness is made of.",
                "Counting to a click rather than watching a clock gives attention something concrete to hold, and the accented click opens each phase, so the turn is heard rather than read.",
                "Honest limits: \"activating\" here describes that breath-by-breath swing and how people report the state, not a measured rise in sympathetic tone, and no trial has compared eyes open against eyes closed for this breath. What is well evidenced is the autonomic effect of breathing at this rate, and that slow breathing before a demanding task improves how well the task goes.",
            ],
            evidence: [decouck2019, you2021, laborde2022, zaccaro2018],
            tags: ["Alert Calm", "Eyes Open", "Sharpness"],
            art: practiceArt,
            // 5 quarter-note counts at 60 BPM: one count a second, 5 s a phase,
            // a 10 s cycle. Counts are whole by construction, which keeps the
            // accent exactly on the turn at any tempo.
            kind: .pacer(BreathPattern(inhale: 5, holdIn: 0, exhale: 5, holdOut: 0)),
            paceControl: .clicksAndNote(defaultNote: .quarter)),

        Practice(
            id: "relaxing-breathing-4x6", title: "Relaxing Breathing 4×6", subtitle: "Four counts in, six counts out",
            category: .breathwork, states: [.stress, .anxiety],
            activityType: .breathwork, subtype: "Relaxing Breathing",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "Four counts in, six counts out, one count a second. The out-breath is half as long again as the in-breath — prolonged exhalation, and the shape that turns slow breathing into a way down. Expect the pulse to settle within the first minute or two and the edge to come off; ten minutes leaves most people calmer than it found them. Eyes closed is fine.",
            howItWorks: [
                "Heart rate falls on every out-breath, as the vagal brake comes back on. Weighting the exhale spends more of each cycle on that side of the swing, so the pulse settles and vagally-mediated heart rate variability rises — the two markers that move first when arousal comes down.",
                "Ten seconds a cycle is six breaths a minute. That is the slow-breathing band where the shift toward the parasympathetic side is best documented, and where the effect carries past the end of the session rather than stopping with it.",
                "This is the pattern to reach for after something stressful, or when anxious arousal is higher than the situation calls for. In the month-long trial below, breathwork weighted toward the exhale improved mood more than the other breathing patterns tested — and lowered anxiety along with it.",
                "Nothing is held at either end and the inhale is unforced, which is what makes ten or twenty minutes sustainable where a more strenuous pattern would not be.",
                "Honest limits: a longer exhale is better evidenced for how it feels — mood, anxiety, perceived calm — than for producing a larger heart-rate-variability number than an even breath would. Take the ratio as the reliable route to the state, not as a bigger reading.",
            ],
            evidence: [balban2023, zaccaro2018, laborde2022],
            tags: ["Longer Exhale", "Down-regulate", "Calm"],
            art: practiceArt,
            // 4 in, 6 out at one quarter-note count a second: a 10 s cycle, so
            // six breaths a minute with the weight on the out-breath.
            kind: .pacer(BreathPattern(inhale: 4, holdIn: 0, exhale: 6, holdOut: 0)),
            paceControl: .clicksAndNote(defaultNote: .quarter)),

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
