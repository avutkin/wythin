import SwiftUI

// MARK: - What a practice actually does, as opposed to what it is filed under
//
// Every slow-breathing practice in a catalogue ends up tagged "calming", and
// that tag hides the thing that matters. Coherent Breathing runs at 6 cycles a
// minute with no holds; Box Breathing at 4:4:4:4 runs at 3.75 with holds on
// both ends; 4-7-8 runs at 3.16 with a seven-second hold on the inhale. The
// last two are not slower versions of the first — they are twice under the
// resonant frequency of the baroreflex and they hold, so the dominant
// mechanism is a rising CO2, not a standing wave in blood pressure.
//
// This file exists so that distinction is a field rather than a paragraph
// somebody might read.

/// What a breathing practice does to the body, grouped by mechanism rather
/// than by the state it is sold for.
enum BreathMechanism: String, CaseIterable, Identifiable, Hashable {
    /// The breath is watched, not changed. The only class that can serve as a
    /// control condition, because it is the only one where rate is not
    /// manipulated.
    case observation
    /// Near six cycles a minute, no holds: the breath lands on the ~0.1 Hz
    /// blood-pressure wave and the heart-rate swing is driven to its maximum.
    case resonance
    /// Slow, but asymmetric — the out-breath carries the weight. The question
    /// this class exists to answer is whether the benefit is the slowing or
    /// the ratio.
    case extendedExhale
    /// A double inhale and one long exhale, repeated. Not a steady rhythm at
    /// all, so a cycles-per-minute figure describes it only loosely.
    case sigh
    /// Holds, or a rate low enough that CO2 climbs between breaths. Grouped
    /// apart from resonance however calming it is described as being.
    case co2Accumulation
    /// Forced and fast: CO2 falls. The mirror image of everything above, and
    /// not to be pooled with it in the same measurement session.
    case hyperventilation
    /// A narrowed airway, a sound, or a nostril closed — the resistance is the
    /// intervention and the rate is a side effect.
    case resistance
    /// A brief move to close out a stress response. Seconds, not minutes, so
    /// it is not a session practice and is not measured as one.
    case recovery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .observation:      return "Observation"
        case .resonance:        return "Resonance"
        case .extendedExhale:   return "Longer Exhale"
        case .sigh:             return "Physiological Sigh"
        case .co2Accumulation:  return "CO₂ Build-up"
        case .hyperventilation: return "Over-breathing"
        case .resistance:       return "Airway Resistance"
        case .recovery:         return "Recovery Move"
        }
    }

    /// One line on what the class does, for the section header it titles.
    var summary: String {
        switch self {
        case .observation:
            return "The breath is watched, not changed — the only practices whose rate is not manipulated."
        case .resonance:
            return "About six cycles a minute, no holds: the breath meets the slow wave already running in your blood pressure."
        case .extendedExhale:
            return "Slow, with the weight on the out-breath. Whether that beats an even breath is the open question."
        case .sigh:
            return "A double in-breath and one long out-breath, repeated. The fastest route down that has been trialled."
        case .co2Accumulation:
            return "Holds, or a rate low enough that carbon dioxide rises between breaths. A different mechanism from resonance, whatever it is called."
        case .hyperventilation:
            return "Forced and fast — carbon dioxide falls. The opposite of everything above, and not to be mixed with it."
        case .resistance:
            return "A narrowed airway or a closed nostril. The resistance is the intervention; the rate follows from it."
        case .recovery:
            return "Seconds, not minutes — a move to end a stress response rather than a session to sit through."
        }
    }

    /// The order the hub lists them in: the control first, then the classes in
    /// descending order of how well the mechanism is established, with the two
    /// that need care last.
    var rank: Int {
        switch self {
        case .observation:      return 0
        case .resonance:        return 1
        case .extendedExhale:   return 2
        case .sigh:             return 3
        case .resistance:       return 4
        case .co2Accumulation:  return 5
        case .hyperventilation: return 6
        case .recovery:         return 7
        }
    }
}

/// How hard the practice is to do correctly, not how strenuous it is.
enum PracticeDifficulty: String, CaseIterable, Hashable {
    case easy, moderate, advanced
    var label: String {
        switch self {
        case .easy:     return "Easy"
        case .moderate: return "Moderate"
        case .advanced: return "Advanced"
        }
    }
}

/// Whether a practice belongs in the app unsupervised.
enum PracticeSupervision: Hashable {
    case unsupervised
    /// Holds and forced over-breathing. Breath-holding and CO2 accumulation
    /// are a recognised laboratory model for provoking panic, and nothing in
    /// an app closes that gap — so these are marked rather than hidden, and
    /// they stay out of the measured comparison set.
    case operatorPresent(reason: String)

    var needsOperator: Bool {
        if case .operatorPresent = self { return true }
        return false
    }
}

/// How fast the practice actually breathes.
///
/// This is the column every other comparison hangs off. Almost every
/// heart-rate-variability measure depends on respiratory rate mechanically, so
/// two practices run at the same rate cannot be told apart by HRV — the
/// reading would be comparing rates, not techniques. A catalogue that does not
/// print this number invites exactly that mistake.
enum BreathRate: Hashable {
    /// Paced, so the rate is known exactly. Derived from the pattern and
    /// tempo the practice ships with rather than typed, so it cannot drift
    /// away from what the pacer actually runs.
    case fixed(cyclesPerMinute: Double, cycleSeconds: Double)
    /// Self-paced within a band — the practice sets a shape, not a clock.
    case range(ClosedRange<Double>)
    /// Not manipulated at all. The control condition.
    case spontaneous
    /// Too fast or too brief for a per-minute figure to mean anything.
    case unrated(String)

    /// "6.0/min", "~5–8/min", "not changed".
    var label: String {
        switch self {
        case .fixed(let cpm, _):
            return String(format: "%.2g/min", cpm)
        case .range(let band):
            return String(format: "~%.2g–%.2g/min", band.lowerBound, band.upperBound)
        case .spontaneous:
            return "not changed"
        case .unrated(let text):
            return text
        }
    }

    /// The cycle in seconds, where there is one to state.
    var cycleLabel: String? {
        switch self {
        case .fixed(_, let secs):
            return secs == secs.rounded() ? "\(Int(secs))s cycle"
                                          : String(format: "%.1fs cycle", secs)
        case .range, .spontaneous, .unrated:
            return nil
        }
    }

    /// A single number to sort and compare by, where one exists.
    var comparableCPM: Double? {
        switch self {
        case .fixed(let cpm, _):   return cpm
        case .range(let band):     return (band.lowerBound + band.upperBound) / 2
        case .spontaneous, .unrated: return nil
        }
    }

    /// The rate a paced practice actually runs at, read off the pattern and
    /// the tempo rather than asserted beside them.
    ///
    /// `note` matters: a practice counted in eighths ticks twice as fast, so a
    /// pattern of ten counts is five seconds rather than ten.
    static func derived(pattern: BreathPattern, bpm: Int, note: NoteValue) -> BreathRate {
        let clicksPerMinute = Double(bpm * note.clicksPerBeat)
        guard clicksPerMinute > 0, pattern.cycleBeats > 0 else { return .unrated("—") }
        let cycleSeconds = Double(pattern.cycleBeats) * 60 / clicksPerMinute
        return .fixed(cyclesPerMinute: 60 / cycleSeconds, cycleSeconds: cycleSeconds)
    }
}

/// The numbers that make two practices comparable — or show that they are not.
struct RespiratoryPassport: Hashable {
    /// Its number in the research catalogue. Sessions are logged by number,
    /// never by name: a session sheet reading "four breathing techniques" and
    /// no numbers is a session whose data cannot be compared with any other.
    let catalogNumber: Int
    let rate: BreathRate
    let hasHolds: Bool
    let mechanism: BreathMechanism
    let difficulty: PracticeDifficulty
    let supervision: PracticeSupervision

    init(catalogNumber: Int,
         rate: BreathRate,
         hasHolds: Bool = false,
         mechanism: BreathMechanism,
         difficulty: PracticeDifficulty = .easy,
         supervision: PracticeSupervision = .unsupervised) {
        self.catalogNumber = catalogNumber
        self.rate = rate
        self.hasHolds = hasHolds
        self.mechanism = mechanism
        self.difficulty = difficulty
        self.supervision = supervision
    }
}
