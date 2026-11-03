import Foundation

// MARK: - Scripted breath
//
// A pacer describes a breath that repeats the same four phases forever. Some
// practices are not that shape. They are a short sequence of distinct moves,
// where a move may be counted out ("hold fifteen") or taken at whatever speed
// the body wants ("breathe in, naturally").
//
// Two things follow from mixing counted and natural steps.
//
// The engine cannot be a pure function of elapsed seconds the way the pacers
// are, because a natural step can be ended early by the person taking it. And
// the session must never count at you: a natural step is walked through with a
// breath sound that runs its whole length, never with clicks, so an own-pace
// breath is guided rather than metered.

/// What the body is doing during one step.
enum BreathMove: String, Equatable, Hashable, CaseIterable {
    case inhale
    case pump         // hold what you have and widen the chest
    case topUp        // one more sip on top of an already full breath
    case exhale
    case holdIn       // sit full
    case holdOut      // sit empty
    case squeezeOut   // press out the last of it

    /// The word in the middle of the circle. Deliberately short: it is read at a
    /// glance, often with the eyes half closed.
    var label: String {
        switch self {
        case .inhale:     return "INHALE"
        case .pump:       return "PUMP"
        case .topUp:      return "TOP UP"
        case .exhale:     return "EXHALE"
        case .holdIn:     return "HOLD"
        case .holdOut:    return "HOLD"
        case .squeezeOut: return "SQUEEZE"
        }
    }

    /// The line under the circle — what to actually do, short enough to take in
    /// during the second or two before the move starts.
    var instruction: String {
        switch self {
        case .inhale:     return "Breathe in, no further than comfortable"
        case .pump:       return "Flare the ribs — one quick push out"
        case .topUp:      return "One strong sip, right to the top"
        case .exhale:     return "Let it go, slowly"
        case .holdIn:     return "Sit full. Jaw and shoulders loose"
        case .holdOut:    return "Sit empty. Let the urge come and pass"
        case .squeezeOut: return "One strong push — all of it out"
        }
    }

    /// Where the lungs end this move, 0 empty … 1 full. A hold returns nil: it
    /// keeps whatever the move before it left, which is the whole point of it.
    var fill: Double? {
        switch self {
        case .inhale:     return 0.72
        case .pump:       return 0.82
        case .topUp:      return 1.00
        case .exhale:     return 0.26
        case .holdIn:     return nil
        case .holdOut:    return nil
        case .squeezeOut: return 0.00
        }
    }

    /// A long sit is left in silence, the way the hold trainer leaves it.
    var isLongHold: Bool { self == .holdIn || self == .holdOut }

    /// The two big efforts, cued with a sweep whose direction is the instruction:
    /// up past full, down past empty.
    var isSurge: Bool { self == .topUp || self == .squeezeOut }

    /// Over in one movement rather than held for a duration — the pump included.
    /// None of these is counted: a move that is finished in a second reads as a
    /// phase to wait out the moment you put a ticking clock on it.
    var isSingleEffort: Bool { isSurge || self == .pump }

    /// Whether the lungs are moving. Drives whether the circle animates over the
    /// step or simply sits where it is.
    var isStill: Bool { fill == nil }
}

/// How long a step lasts, and whether it is counted.
enum BreathPace: Equatable, Hashable {
    /// Seconds, ticked and shown as a countdown.
    case counted(Int)
    /// Your own speed. The number is only how long the guide waits before moving
    /// on by itself — a tap ends it sooner.
    case natural(Int)

    var seconds: Int {
        switch self {
        case .counted(let s), .natural(let s): return max(1, s)
        }
    }

    var isNatural: Bool {
        if case .natural = self { return true }
        return false
    }
}

struct BreathStep: Equatable, Hashable {
    let move: BreathMove
    let pace: BreathPace
}

/// An ordered sequence of moves that repeats as one cycle.
struct BreathScript: Equatable, Hashable {
    let steps: [BreathStep]

    var cycleSeconds: Int { steps.reduce(0) { $0 + $1.pace.seconds } }

    var hasLongHolds: Bool { steps.contains { $0.move.isLongHold } }

    /// The script with its adjustable lengths applied: long holds take `hold`,
    /// natural steps take `natural`.
    ///
    /// The short counted moves — the pump, the top-up, the squeeze — keep the
    /// length the script gives them. Their length is part of what the move *is*,
    /// and there is nothing useful to decide about a two-second sip.
    func resized(hold: Int, natural: Int) -> BreathScript {
        BreathScript(steps: steps.map { step in
            switch step.pace {
            case .natural:
                return BreathStep(move: step.move, pace: .natural(max(1, natural)))
            case .counted(let seconds):
                return BreathStep(move: step.move,
                                  pace: .counted(step.move.isLongHold ? max(1, hold) : seconds))
            }
        })
    }

    // MARK: The shipped scripts

    /// Breath stacking. Take a normal breath, flare the ribs against it for a
    /// second, then sip more air on top of what is already there, then let the
    /// whole thing go. Each cycle reaches a fuller inflation than one breath on
    /// its own would.
    static let stacking = BreathScript(steps: [
        BreathStep(move: .inhale, pace: .natural(4)),
        // One second. The pump is a flick of the ribs, not a phase — long enough
        // to make the movement, and no longer.
        BreathStep(move: .pump,   pace: .counted(1)),
        BreathStep(move: .topUp,  pace: .counted(2)),
        BreathStep(move: .exhale, pace: .natural(6)),
    ])

    /// A retention on both ends, each finished by pushing one step past where
    /// the breath wanted to stop: a sip at the top of the full hold, a squeeze
    /// at the bottom of the empty one.
    static let retention = BreathScript(steps: [
        BreathStep(move: .inhale,     pace: .natural(4)),
        BreathStep(move: .holdIn,     pace: .counted(15)),
        BreathStep(move: .topUp,      pace: .counted(2)),
        BreathStep(move: .exhale,     pace: .natural(5)),
        BreathStep(move: .holdOut,    pace: .counted(15)),
        BreathStep(move: .squeezeOut, pace: .counted(2)),
    ])
}
