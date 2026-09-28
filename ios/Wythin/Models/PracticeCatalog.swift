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
            kind: .pacer(.box),
            catalogNumber: 9, mechanism: .co2Accumulation, difficulty: .easy,
            supervision: .operatorPresent(reason: "Holds on both ends. Breath-holding and the CO₂ it accumulates are a recognised laboratory model for provoking panic, so this sits outside the measured comparison set.")),

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
            kind: .pacer(EvenCadence.resonance.pattern),
            catalogNumber: 31, mechanism: .resonance, difficulty: .moderate),

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
            catalogNumber: 7, mechanism: .resonance, difficulty: .easy,
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
            catalogNumber: 8, mechanism: .extendedExhale, difficulty: .easy,
            paceControl: .clicksAndNote(defaultNote: .quarter)),

        // ── The control condition ────────────────────────────────────────
        //
        // First in the list on purpose. It is the only practice here whose
        // rate is not manipulated, which makes it the only one that can serve
        // as a control: without it, every effect the others show is
        // indistinguishable from the effect of sitting still with your eyes
        // shut for fifteen minutes.

        Practice(
            id: "anapanasati", title: "Anapanasati", subtitle: "Watch the breath. Change nothing.",
            category: .breathwork, states: [.focus, .stress],
            activityType: .meditation, subtype: "Anapanasati",
            defaultDurationMins: 15, defaultBPM: 60,
            description: "Attention rests on the breath where you feel it most clearly — at the nostrils, or in the belly — and the breath is left entirely alone. Long or short, rough or smooth, you note it and let it be. There is no pacer here and there is not meant to be: the instant you start steering the breath, this becomes a different practice.",
            howItWorks: [
                "Every other practice in this catalogue changes your breathing rate, and almost every heart-rate-variability number moves mechanically with that rate. This one does not change it — which is what makes it the measuring stick the others are read against.",
                "What is left when the rate is held constant is the effect of attention itself: sitting still, eyes closed, mind on one object. That effect is real and it is not nothing, and it is exactly the part that a paced practice cannot claim credit for.",
                "Practically: if you catch yourself lengthening the exhale because it feels better, you have left the practice. Note it, and hand the breath back.",
                "Honest limits: the evidence for attention-on-breath meditation is a separate literature from the slow-breathing evidence the paced practices rest on, and the two should not be borrowed across. Nothing is cited here for a physiological effect, because the point of this practice in this app is to have none.",
            ],
            evidence: [],
            tags: ["Control", "Unpaced", "Attention"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 19, mechanism: .observation, difficulty: .easy,
            rate: .spontaneous),

        // ── Longer exhale ────────────────────────────────────────────────

        Practice(
            id: "one-to-two-4x8", title: "1:2 Breathing 4×8", subtitle: "Four counts in, eight counts out",
            category: .breathwork, states: [.anxiety, .stress],
            activityType: .breathwork, subtype: "Relaxing Breathing",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "Four counts in, eight counts out — the out-breath twice the length of the in-breath, at one count a second. A twelve-second cycle, so five breaths a minute. This is the one to reach for when arousal is already high and the even breaths feel like too much work to hold.",
            howItWorks: [
                "The ratio is the whole point. Its sibling in this catalogue, Relaxing Breathing 4×6, runs at the same six cycles a minute as the resonance practices, so a difference between those two is hard to read. This one runs at five, with a doubled exhale, and is the cleaner test of whether the ratio or the slowing is doing the work.",
                "Heart rate falls through every out-breath as the vagal brake re-engages. Spending two-thirds of each cycle there is the most exhale-weighted shape most people can hold for ten minutes without straining.",
                "A doubled exhale is slow going at first. If the last counts feel forced, shorten the whole cycle rather than breaking the ratio — the ratio is what you are practising.",
                "Honest limits: exhale-weighted breathing is better evidenced for how it feels than for producing a larger variability number than an even breath at the same rate. Take the shape as the route to the state, not as a bigger reading.",
            ],
            evidence: [balban2023, zaccaro2018, laborde2022],
            tags: ["1:2 Ratio", "Down-regulate", "Acute Anxiety"],
            art: practiceArt,
            kind: .pacer(BreathPattern(inhale: 4, holdIn: 0, exhale: 8, holdOut: 0)),
            catalogNumber: 28, mechanism: .extendedExhale, difficulty: .easy,
            paceControl: .clicksAndNote(defaultNote: .quarter)),

        // ── The sigh ─────────────────────────────────────────────────────

        Practice(
            id: "cyclic-sighing", title: "Cyclic Sighing", subtitle: "Two breaths in, one long breath out",
            category: .breathwork, states: [.stress, .anxiety],
            activityType: .breathwork, subtype: "Cyclic Sighing",
            defaultDurationMins: 5, defaultBPM: 60,
            description: "Breathe in through the nose, then — without breathing out — take a second, shorter sip of air on top. Then let it all go slowly through the mouth, longer than both inhales together. Repeat. Five minutes is the tested dose, and it is the whole session; this is not a practice you sit in for twenty.",
            howItWorks: [
                "The double inhale is not a flourish. It reinflates alveoli that have collapsed, which is what a spontaneous sigh does perhaps a dozen times an hour without you noticing — this practice simply does it deliberately and repeatedly.",
                "The long, unhurried exhale that follows is where heart rate falls. The combination is why the effect arrives in minutes rather than over a course of weeks.",
                "In the trial below, five minutes a day of this beat both the other breathwork patterns tested and mindfulness meditation on mood improvement and on lowering resting breathing rate, over a month.",
                "Because the rhythm is not steady, a cycles-per-minute figure only loosely describes it — expect somewhere around five to eight. That is worth knowing before comparing its variability numbers with a metronome-paced practice.",
                "Honest limits: the headline trial is a single month-long study with self-reported mood as the primary outcome. It is the freshest and best-controlled evidence in this catalogue, and it is still one study.",
            ],
            evidence: [balban2023, laborde2022],
            tags: ["Physiological Sigh", "Five Minutes", "Fast Relief"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 23, mechanism: .sigh, difficulty: .easy,
            rate: .range(5...8)),

        // ── CO₂ build-up ─────────────────────────────────────────────────

        Practice(
            id: "four-seven-eight", title: "4-7-8 Breathing", subtitle: "In for four, hold seven, out for eight",
            category: .breathwork, states: [.sleep, .anxiety],
            activityType: .breathwork, subtype: "4-7-8 Breathing",
            defaultDurationMins: 5, defaultBPM: 60,
            description: "In through the nose for four counts, hold for seven, out through the mouth for eight. A nineteen-second cycle — a shade over three breaths a minute, which is roughly half the rate of the resonance practices. Usually done in four to eight cycles rather than for a set number of minutes, and most often at bedtime.",
            howItWorks: [
                "Filed as calming, but the mechanism is not the one the even-breath practices use. At three cycles a minute with a seven-count hold, carbon dioxide rises between breaths; the breath is nowhere near the ten-second wave that resonance breathing is built to meet. Grouping it with Coherent Breathing because both are slow would be grouping them by their labels.",
                "The long exhale does engage the vagal brake, and the hold does concentrate attention. Both are real. What the pattern is not is a slower version of a resonance breath.",
                "A rising CO₂ is also what makes this one to approach carefully. Air hunger is the sensation, and for some people it is the trigger rather than the remedy — if the hold brings on alarm rather than settling, stop and use an even breath instead.",
                "Honest limits: this pattern is widely taught and thinly trialled. There is no controlled study in this catalogue supporting 4-7-8 specifically, and none is cited here rather than borrowing one about slow breathing in general — which is a different thing at a different rate.",
            ],
            evidence: [],
            tags: ["Hold", "Bedtime", "CO₂"],
            art: practiceArt,
            kind: .pacer(BreathPattern(inhale: 4, holdIn: 7, exhale: 8, holdOut: 0)),
            catalogNumber: 22, mechanism: .co2Accumulation, difficulty: .easy,
            supervision: .operatorPresent(reason: "A seven-count hold on a full breath. CO₂ accumulation is a recognised panic-provocation model, so this stays outside the measured comparison set.")),

        // ── Airway resistance ────────────────────────────────────────────

        Practice(
            id: "bhramari", title: "Bhramari", subtitle: "Hum the whole way out",
            category: .breathwork, states: [.anxiety, .stress],
            activityType: .breathwork, subtype: "Bhramari",
            defaultDurationMins: 8, defaultBPM: 60,
            description: "Breathe in normally through the nose, then hum on the way out — a steady, low bee-like sound held until the breath runs out. Ears lightly closed with the fingers makes the sound fill your head, which is most of the point. The humming stretches the exhale on its own, so the rate settles somewhere around five to seven a minute without being counted.",
            howItWorks: [
                "Humming narrows the airway at the vocal folds. The out-breath is slowed by the resistance rather than by a count, so the practice produces a long exhale without anyone having to hold one deliberately.",
                "The vibration is also a sensory object — an unusually absorbing one, which is why this is often the practice that works for people who cannot settle into a counted breath.",
                "Nasal humming markedly raises nasal nitric oxide, which is a well-replicated measurement. What that does for anxiety or sleep is a separate question and much less settled; the two are often run together in claims about this practice, and they should not be.",
                "Honest limits: the trial literature is small, mostly unblinded and mostly from a single region. Treat this as a technique with a clear mechanism for slowing the exhale and thin clinical evidence for the rest.",
            ],
            evidence: [zaccaro2018],
            tags: ["Humming", "Resistance", "Absorbing"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 16, mechanism: .resistance, difficulty: .easy,
            rate: .range(5...7)),

        Practice(
            id: "ujjayi", title: "Ujjayi", subtitle: "Breathe through a narrowed throat",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Ujjayi",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "Breathe in and out through the nose with the back of the throat slightly closed, as if fogging a window with the mouth shut. The sound is soft and oceanic and should be even in both directions. The narrowing slows the breath by itself — expect something in the five-to-eight range without counting.",
            howItWorks: [
                "The constriction is a flow restrictor. It lengthens both phases evenly, which makes this the resistance practice closest in shape to an even paced breath — and the one whose effects are hardest to separate from simply breathing slowly.",
                "The sound gives attention a continuous object, which is why this is the breath used to hold a long posture sequence together rather than a breath practised on its own.",
                "Keep the effort in the throat, not the jaw or the face. Strain in this practice shows up as tension, and tension is the thing it is meant to be dissolving.",
                "Honest limits: cited here for what the mechanism plainly does — slow the breath — using the general slow-breathing evidence. No trial in this catalogue tested ujjayi against an unrestricted breath at the same rate, which is the comparison that would show whether the resistance adds anything.",
            ],
            evidence: [zaccaro2018, laborde2022],
            tags: ["Ocean Breath", "Resistance", "Steady"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 5, mechanism: .resistance, difficulty: .easy,
            rate: .range(5...8)),

        Practice(
            id: "nadi-shodhana", title: "Nadi Shodhana", subtitle: "One nostril at a time",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Nadi Shodhana",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "Close the right nostril and breathe in through the left; close the left and breathe out through the right; in through the right, out through the left. That is one round. The hand does the switching, so the breath is unhurried by necessity — four to six cycles a minute is typical.",
            howItWorks: [
                "Half the airway at a time roughly doubles the resistance, which slows the breath and deepens it without any counting. Most of the measurable effect is likely this, and it is the part that is not in dispute.",
                "The alternation itself is the interesting claim: that left and right nostrils bias the nervous system differently. Nasal airflow really does alternate through the day on its own — the nasal cycle is a real and measured phenomenon — but that a person can shift autonomic balance by choosing a side is a much larger claim resting on much smaller studies.",
                "The switching also occupies the hands and requires tracking where you are in the round, which is a genuine attentional load. For some people that is the practice's advantage; for others it is what makes it impossible to settle into.",
                "Honest limits: cited on the slow-breathing evidence, which covers the rate but not the alternation. Take the laterality claims as untested here rather than as supported.",
            ],
            evidence: [zaccaro2018, laborde2022],
            tags: ["Alternate Nostril", "Balancing", "Hands Busy"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 14, mechanism: .resistance, difficulty: .moderate,
            rate: .range(4...6)),

        Practice(
            id: "full-yogic-breath", title: "Full Yogic Breath", subtitle: "Belly, ribs, chest — then let it go",
            category: .breathwork, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Full Yogic Breath",
            defaultDurationMins: 10, defaultBPM: 60,
            description: "Fill from the bottom up: the belly first, then the ribs widening sideways, then the upper chest. Let it out in the reverse order, unhurried and complete. Nothing is held. A full breath takes long enough that the rate lands around four to six a minute on its own.",
            howItWorks: [
                "This is the foundation the other practices assume you already have. Most people breathe shallowly into the upper chest; using the diaphragm properly moves considerably more air per breath, which is what makes a slow rate comfortable rather than a struggle.",
                "The diaphragm's downward travel is also what drives the pressure swing the vagal brake reads. A breath that only moves the chest produces a much smaller swing at the same rate — so technique, not just tempo, is doing work here.",
                "Learn this one lying down with a hand on the belly and a hand on the ribs before trying to apply it to anything paced. The pacer practices get easier once this is automatic.",
                "Honest limits: cited on the general slow-breathing evidence, which is about the rate this produces rather than about the layered technique specifically.",
            ],
            evidence: [zaccaro2018, laborde2022],
            tags: ["Foundation", "Diaphragm", "Unpaced"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 15, mechanism: .extendedExhale, difficulty: .easy,
            rate: .range(4...6)),

        Practice(
            id: "sitali", title: "Sitali / Sitkari", subtitle: "Draw the air in cool",
            category: .breathwork, states: [.stress, .anxiety],
            activityType: .breathwork, subtype: "Sitali",
            defaultDurationMins: 6, defaultBPM: 60,
            description: "Curl the tongue into a tube and breathe in through it — or, if your tongue does not curl, draw the air in through lightly clenched teeth with the lips parted. That is Sitkari, and it works the same way. Breathe out through the nose. The air arrives noticeably cool.",
            howItWorks: [
                "Drawing air across a wet tongue cools it by evaporation. The sensation is unmistakable and immediate, which is most of what this practice offers: a strong, novel sensory anchor that is hard to think past.",
                "The narrow opening also restricts flow, so the in-breath lengthens and the rate falls to somewhere around six to eight a minute without being counted.",
                "Traditionally used for heat and irritability. The cooling is real at the mouth; a claim that it lowers body temperature is a much bigger one and is not supported here.",
                "Honest limits: essentially untrialled as a discrete intervention. It is in the catalogue as a distinct mechanism worth measuring, not as a technique with evidence behind it.",
            ],
            evidence: [],
            tags: ["Cooling", "Sensory", "Irritability"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 17, mechanism: .resistance, difficulty: .easy,
            rate: .range(6...8)),

        // ── Over-breathing ───────────────────────────────────────────────

        Practice(
            id: "kapalabhati", title: "Kapalabhati", subtitle: "Sharp out, passive in",
            category: .breathwork, states: [.focus],
            activityType: .breathwork, subtype: "Kapalabhati",
            defaultDurationMins: 3, defaultBPM: 60,
            description: "Short, sharp exhales driven by the abdominal wall, with the in-breath left to happen by itself between them. One to two a second, in rounds of twenty to thirty, resting fully between rounds. This is the one practice here that speeds the breath up rather than slowing it.",
            howItWorks: [
                "Sixty to a hundred and twenty breaths a minute drives carbon dioxide down — the exact opposite of every other practice in this catalogue, which either leave it alone or let it rise. That is why it must never be measured in the same session as the calming techniques: pooled, the two mechanisms cancel and the results mean nothing.",
                "The falling CO₂ constricts cerebral blood vessels, which is where the light-headedness and the tingling in the hands come from. Those are the mechanism showing itself, not a sign the practice is working especially well.",
                "The work is entirely in the abdominal wall on the exhale. If the shoulders are lifting or the in-breath is being pulled, the pattern has become plain fast breathing.",
                "Honest limits: not suitable during pregnancy, with uncontrolled high blood pressure, glaucoma, epilepsy, or a recent abdominal surgery, and not to be done standing or in water. No controlled trial is cited here because the ones in this catalogue are all about slow breathing, which this is not.",
            ],
            evidence: [],
            tags: ["Activation", "Fast", "Rounds"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 3, mechanism: .hyperventilation, difficulty: .moderate,
            supervision: .operatorPresent(reason: "Forced hyperventilation. Drives CO₂ down, causes light-headedness by design, and carries real contraindications."),
            rate: .unrated("60–120/min")),

        // ── Recovery move ────────────────────────────────────────────────

        Practice(
            id: "hook-breath", title: "Hook Breath", subtitle: "Fifteen seconds to close a spike",
            category: .breathwork, states: [.stress],
            activityType: .breathwork, subtype: "Hook Breath",
            defaultDurationMins: 1, defaultBPM: 60,
            description: "A short, firm inhale, then a forceful exhale against a braced trunk — the sound is a sharp \"hook\". Two or three of them, fifteen to thirty seconds in total, and then you go back to breathing normally. It is a move, not a session.",
            howItWorks: [
                "This does not belong in the row of practices you sit down and do. Its question is a different one: whether a brief intervention immediately after a stressor speeds the return to baseline compared with simply waiting.",
                "That is tested as a pairing, not as a session — stressor then twenty minutes of ordinary breathing, against stressor then this then ordinary breathing, comparing the final minutes where both are breathing the same way. Anything else confounds the move with the rest.",
                "The bracing raises intrathoracic pressure briefly, which is a real haemodynamic event rather than a relaxation technique. Expect it to feel like effort.",
                "Honest limits: untested here, and in the catalogue as a recovery hypothesis to be measured rather than a practice to be recommended.",
            ],
            evidence: [],
            tags: ["Fifteen Seconds", "After A Spike", "Recovery"],
            art: practiceArt,
            kind: .content,
            catalogNumber: 25, mechanism: .recovery, difficulty: .moderate,
            rate: .unrated("15–30s total")),

        Practice(
            id: "breath-stacking", title: "Breath Stacking", subtitle: "In, pump, top up, release",
            category: .breathwork, states: [.focus, .stress],
            activityType: .breathwork, subtype: "Breath Stacking",
            defaultDurationMins: 5, defaultBPM: 60,
            description: "Breathe in as you normally would. Hold what you have and widen the ribs against it — a pump rather than more air. Then take one more sip right to the top, and let the whole thing go slowly. Each round reaches a fuller chest than a single breath gets to on its own. Sit upright, work at the edge of comfortable rather than past it, and stop if you feel light-headed.",
            howItWorks: [
                "Stacking one inhale on another reaches an inflation an ordinary breath does not, which opens parts of the lungs that quiet breathing leaves under-used and puts a real stretch through the ribs and diaphragm.",
                "A large inflation loads the stretch receptors in the lungs and the slow exhale that follows unloads them. That rise-and-release is a strong version of the swing every slow breath makes, which is why the exhale here is the part to take your time over.",
                "The pump is what makes it a practice rather than a big breath: holding the air and widening the chest against it is a movement, and doing it deliberately is how the ribcage keeps the range it otherwise loses.",
                "Honest limits: stacked inhalation is well established as a clinical technique for people who cannot fill their lungs unaided, where it is used to improve inspiratory volume and cough. Its use as a wellbeing practice in healthy adults borrows that mechanic without a trial behind it. The slow exhale is the part with the evidence.",
            ],
            evidence: [zaccaro2018, balban2023, laborde2022],
            tags: ["Chest Opening", "Full Inflation", "Release"],
            art: practiceArt,
            kind: .scripted(.stacking),
            catalogNumber: 26, mechanism: .co2Accumulation, difficulty: .moderate,
            supervision: .operatorPresent(reason: "Stacked inhales raise intrathoracic pressure and are held at the top."),
            rate: .unrated("stacked, not cyclic")),

        Practice(
            id: "breath-retention-15x15", title: "Breath Retention 15×15", subtitle: "Fifteen full, fifteen empty",
            category: .breathwork, states: [.stress, .focus],
            activityType: .breathwork, subtype: "Breath Retention",
            defaultDurationMins: 8, defaultBPM: 60,
            description: "Breathe in naturally and sit full for fifteen. Take one more sip at the top, let it go, and sit empty for fifteen. Then press out the last of it and let the next breath come in on its own. Both ends of the breath are held, and both are finished a step past where the breath wanted to stop. Sit or lie down on land — never in or near water — and let a round go if the urge to breathe turns sharp.",
            howItWorks: [
                "Holding on full and on empty raises carbon dioxide, and the urge to breathe is a response to that rather than to running out of oxygen. Meeting the urge without acting on it is the thing being trained; the fifteen seconds is only the container.",
                "A hold also brings on the diving response — the heart slows and the spleen squeezes a reserve of red cells into circulation — and repeating it is the stimulus the adaptations are built on.",
                "The sip at the top and the squeeze at the bottom are the working part of each end. Going one step past where the breath would have stopped is what makes the range the practice trains, rather than simply waiting out a clock.",
                "The natural breath between the holds is deliberately not counted. Chasing a pace immediately after a retention is how people end up over-breathing, so the guide waits on you there instead.",
                "Honest limits: the adaptations documented below come from divers holding far longer than this, and the review raises open questions about very heavy long-term practice. Short holds are where the risk-to-benefit sits well.",
            ],
            evidence: [elia2021, persson2023, kox2014],
            tags: ["CO2 Tolerance", "Both Ends", "Composure"],
            art: practiceArt,
            kind: .scripted(.retention),
            catalogNumber: 11, mechanism: .co2Accumulation, difficulty: .advanced,
            supervision: .operatorPresent(reason: "Fifteen seconds held full and fifteen empty. CO₂ accumulation is a panic-provocation model and belongs in the supervised branch."),
            rate: .fixed(cyclesPerMinute: 2, cycleSeconds: 30)),

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
            kind: .holdTrainer(.standard),
            catalogNumber: 13, mechanism: .co2Accumulation, difficulty: .advanced,
            supervision: .operatorPresent(reason: "Maximal holds on empty lungs, in sets."),
            rate: .unrated("set-based")),
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
