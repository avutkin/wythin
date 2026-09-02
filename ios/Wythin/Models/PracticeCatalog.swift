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
            id: "coherent-breathing", title: "Coherent Breathing", subtitle: "Counted to a metronome you set",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Coherent Breathing",
            defaultDurationMins: 12, defaultBPM: 60,
            description: "The same even breath as Resonance, worked the other way round. You set the tempo, what a count is worth against it, and how many counts the inhale and the exhale each get — and the seconds fall out of those three. It opens on eleven eighth-note counts at 60 BPM: five and a half seconds a side, about five and a half breaths a minute. Counting to the click is the practice.",
            howItWorks: [
                "At around five and a half seconds each way the breath sits in the band where heart and blood-pressure control lock together, and heart rate variability reaches its widest swing.",
                "Counting to a click rather than watching a clock gives attention something concrete to hold, and the accented click opens each phase — so the turn is heard rather than read.",
                "The inhale and the exhale are counted separately, so a longer exhale is a matter of counting further rather than a different practice. A longer out-breath than in-breath leans the balance further toward the vagal side.",
                "On the honest side of the ledger: the physiological effect is well evidenced, and better decisions after slow breathing have been measured directly. Creative output specifically has not — the link there rests on correlations between heart rate variability and divergent thinking, not on trials. Treat the creative framing as the reason to try it, not as a finding.",
            ],
            evidence: [decouck2019, laborde2022, zaccaro2018],
            tags: ["Coherence", "Loose Attention", "Ideas"],
            art: practiceArt,
            // Eleven counts at an eighth of a 60 BPM beat: 0.5 s a count, so
            // 5.5 s a phase. Counts are whole by construction, which is what
            // keeps the accent exactly on the turn at any tempo.
            kind: .pacer(.even(beats: 11)),
            paceControl: .clicksAndNote(defaultNote: .eighth)),

        Practice(
            id: "hearing-breathing-5x5", title: "Hearing Breathing 5×5", subtitle: "Five counts in, five out, eyes open",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Hearing Breathing",
            defaultDurationMins: 6, defaultBPM: 60,
            description: "Five counts in, five counts out, at one count a second. An even breath with no weight on either side — and unlike most slow breathing, it is meant to sharpen rather than settle you. Do it with your eyes open, looking at something. Keeping the visual field engaged is what keeps the session alert; close your eyes and the same breath will drift toward a wind-down.",
            howItWorks: [
                "Equal counts give the in-breath as much room as the out-breath. Heart rate climbs through each inhale as the vagal brake eases and falls through each exhale as it comes back on, so the swing is large and symmetrical — the rousing half and the calming half in equal measure. That balance is what the sharpness is made of.",
                "Five seconds a side is ten seconds a cycle: six breaths a minute, the rate at which that swing is widest and vagally-mediated heart rate variability peaks.",
                "Eyes open is the instruction that makes it activating rather than settling. Attention stays pointed outward at something real, so the calm arrives without the drowsiness. Treat that as a practice instruction — no trial has compared eyes open against eyes closed for this breath.",
                "Honest limits: \"activating\" here describes the breath-by-breath swing and how people report the state, not a measured rise in sympathetic tone. What is well evidenced is the autonomic effect of breathing at this rate, and that slow breathing before a demanding task improves how well the task goes.",
            ],
            evidence: [decouck2019, you2021, laborde2022],
            tags: ["Alert Calm", "Eyes Open", "Sharpness"],
            art: practiceArt,
            // 5 quarter-note counts at 60 BPM: one count a second, 5 s a phase.
            kind: .pacer(BreathPattern(inhale: 5, holdIn: 0, exhale: 5, holdOut: 0)),
            paceControl: .clicksAndNote(defaultNote: .quarter)),

        Practice(
            id: "calming-breath-4x6", title: "Calming Breath 4×6", subtitle: "Four counts in, six counts out",
            category: .breathwork, states: [.stress, .anxiety],
            activityType: .breathwork, subtype: "Calming Breath",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "The same clock as Hearing Breathing — one count a second, ten seconds a cycle — with the weight moved onto the out-breath: four counts in, six counts out. Same rate, opposite intent. This is the one to reach for when you want to come down rather than sharpen up, and it works comfortably with the eyes closed.",
            howItWorks: [
                "Heart rate falls while you breathe out, as the vagal brake is reapplied. Making the exhale half as long again as the inhale spends more of every cycle on that side of the swing, which is why a lengthened out-breath is the oldest instruction in the calming repertoire.",
                "The cycle still totals ten seconds, so this keeps the six-breaths-a-minute benefit that the even version has — it leans the ratio without leaving the band.",
                "Nothing is held at either end. A 4–6 breath asks for no breath-holding and no effort on the inhale, which is what makes twenty minutes of it possible where a more strenuous pattern would not be.",
                "Honest limits: the head-to-head trial below found exhale-focused breathing improved mood the most of the styles it tested. The specific claim that a longer exhale raises heart rate variability more than an even breath does is not settled — the ratio is better supported for how the practice feels than for a bigger number.",
            ],
            evidence: [balban2023, zaccaro2018, laborde2022],
            tags: ["Longer Exhale", "Down-regulate", "Calm"],
            art: practiceArt,
            // 4 in, 6 out at one quarter-note count a second: a 10 s cycle, so
            // still six breaths a minute — the weight moved, not the rate.
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
