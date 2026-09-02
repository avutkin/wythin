import Foundation

// MARK: - Breath patterns
//
// A four-part breath, counted in BEATS per phase rather than seconds. The
// metronome's tempo decides how long a beat lasts, so a phase is always a whole
// number of beats and the accented beat opening a phase always lands exactly on
// the phase change — at any tempo. At the default 60 BPM a beat is a second, so
// 6-6-6-6 reads as the familiar six-second box.

enum BreathPhase: Int, CaseIterable, Identifiable {
    case inhale, holdIn, exhale, holdOut
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .inhale:  return "INHALE"
        case .exhale:  return "EXHALE"
        case .holdIn,
             .holdOut: return "HOLD"
        }
    }

    /// Whether the lungs move during this phase — the inner circle animates on
    /// inhale and exhale, and sits still through the holds.
    var isHold: Bool { self == .holdIn || self == .holdOut }
}

struct BreathPattern: Equatable, Hashable {
    let inhale:  Int
    let holdIn:  Int
    let exhale:  Int
    let holdOut: Int

    /// Six beats a side — at 60 BPM, a 24-second cycle and 2.5 breaths a minute.
    static let box = BreathPattern(inhale: 6, holdIn: 6, exhale: 6, holdOut: 6)

    /// Even in, even out, no holds — at 60 BPM a 10-second cycle, which is six
    /// breaths a minute: the rate around which heart-rate variability peaks.
    static let resonance = BreathPattern(inhale: 5, holdIn: 0, exhale: 5, holdOut: 0)

    /// An even in-and-out breath of `beats` a side, which is what the pace
    /// control produces for a hold-free pattern.
    static func even(beats: Int) -> BreathPattern {
        BreathPattern(inhale: beats, holdIn: 0, exhale: beats, holdOut: 0)
    }

    /// An equal-sided box of `beats` per phase, which is what the pace control
    /// produces — a box breath is symmetric by definition.
    static func box(beats: Int) -> BreathPattern {
        BreathPattern(inhale: beats, holdIn: beats, exhale: beats, holdOut: beats)
    }

    func beats(_ phase: BreathPhase) -> Int {
        switch phase {
        case .inhale:  return inhale
        case .holdIn:  return holdIn
        case .exhale:  return exhale
        case .holdOut: return holdOut
        }
    }

    var cycleBeats: Int { inhale + holdIn + exhale + holdOut }

    /// Whether the breath pauses at the top and bottom. Hold-free patterns pace
    /// on a ring rather than a box — there are only two phases to show.
    var hasHolds: Bool { holdIn > 0 || holdOut > 0 }

    /// The phases that actually run, in order. A zero-beat hold is not a phase.
    var activePhases: [BreathPhase] {
        BreathPhase.allCases.filter { beats($0) > 0 }
    }

    /// Beats elapsed in a cycle before this phase begins.
    func beatsBefore(_ phase: BreathPhase) -> Int {
        BreathPhase.allCases
            .prefix(while: { $0 != phase })
            .reduce(0) { $0 + beats($1) }
    }

    /// How long one cycle lasts at a given tempo.
    func cycleSeconds(bpm: Int) -> Double {
        guard bpm > 0 else { return 0 }
        return Double(cycleBeats) * 60.0 / Double(bpm)
    }

    /// Breaths a minute at a given tempo — what the pace control is really setting.
    func breathsPerMinute(bpm: Int) -> Double {
        let cycle = cycleSeconds(bpm: bpm)
        return cycle > 0 ? 60.0 / cycle : 0
    }

    /// "6-6-6-6", or just "5-5" when there are no holds to report.
    var label: String {
        hasHolds ? "\(inhale)-\(holdIn)-\(exhale)-\(holdOut)" : "\(inhale)-\(exhale)"
    }
}

// MARK: - Note value
//
// What one count is worth against the tempo. The tempo is read in quarter notes,
// the way a metronome is set, so an eighth-note count clicks twice per beat.
// That is what lets a phase of eleven counts run 5.5 s at a 60 BPM tempo rather
// than 11 s — the tempo you set and the count you keep stay independent.
//
// Only halves of a quarter are offered, so the click rate is always a whole
// number of beats a minute and the accent cannot land between clicks.

enum NoteValue: Int, CaseIterable, Identifiable {
    case quarter = 4
    case eighth  = 8

    var id: Int { rawValue }

    /// "1/4", "1/8" — how the control names it.
    var label: String { "1/\(rawValue)" }

    /// Clicks per quarter-note beat: the factor the tempo is multiplied by to
    /// get the rate the engine actually ticks at.
    var clicksPerBeat: Int { rawValue / 4 }
}

// MARK: - Even cadence
//
// A hold-free breath is the one practice people describe in seconds — "five and
// a half each way" — not in beats and a tempo. But the engine counts whole beats
// on purpose: that is what keeps the accented beat landing exactly on the phase
// change at any speed.
//
// This type is the bridge. It stores half-seconds and picks the coarsest tick
// that still divides the phase into whole beats: once a second for a whole
// number, twice a second when the value lands on a half. So 5.5 s is reachable
// without anyone being shown a BPM, and 5 s does not get a busier tick than it
// needs.

struct EvenCadence: Equatable, Hashable {
    /// 11 → 5.5 s each way.
    let halfSeconds: Int

    static let resonance = EvenCadence(halfSeconds: 11)   // 5.5 s, ~5.5 breaths/min

    /// The range the pace control offers: 3 s to 8 s a side.
    static let range = 6...16

    init(halfSeconds: Int) { self.halfSeconds = halfSeconds }

    /// Recover the cadence a practice ships with from the pattern and tempo it
    /// was declared with, so the pace control can be seeded from the catalog.
    init(beats: Int, bpm: Int) {
        self.halfSeconds = bpm > 0 ? beats * 120 / bpm : 0
    }

    var seconds: Double { Double(halfSeconds) / 2 }

    private var isWholeSecond: Bool { halfSeconds % 2 == 0 }

    /// One tick a second when the phase is a whole number of seconds, two when
    /// it is not — the least busy beat that can still express the pace exactly.
    var bpm: Int { isWholeSecond ? 60 : 120 }

    var beats: Int { isWholeSecond ? halfSeconds / 2 : halfSeconds }

    var pattern: BreathPattern { .even(beats: beats) }

    var breathsPerMinute: Double {
        let cycle = seconds * 2
        return cycle > 0 ? 60 / cycle : 0
    }

    /// "5.5s" or "5s" — no trailing zero on a whole number.
    var label: String {
        isWholeSecond ? "\(halfSeconds / 2)s" : String(format: "%.1fs", seconds)
    }
}
