import Foundation

// MARK: - Breath-hold protocol
//
// A set-based practice rather than a repeating cadence, so it does not fit
// BreathPattern: each set is two paced breaths and then a hold, and the whole
// thing ends after a fixed number of sets rather than running until stopped.
//
// The hold sits after the exhale — on empty lungs. That is a markedly stronger
// stimulus than the same clock time held on full lungs, which is why the
// defaults here are short and the session's own copy says to start short.

enum HoldPhase: Int, CaseIterable, Identifiable {
    case inhale, exhale, hold
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .inhale: return "INHALE"
        case .exhale: return "EXHALE"
        case .hold:   return "HOLD"
        }
    }
}

struct HoldProtocol: Equatable, Hashable {
    /// Applies to the inhale and the exhale alike — the two paced breaths that
    /// lead into each hold.
    let breatheSeconds: Int
    let holdSeconds:    Int
    let sets:           Int

    /// Twenty seconds on empty, five times. Deliberately modest: this is the
    /// number a first session should meet, not a target.
    static let standard = HoldProtocol(breatheSeconds: 5, holdSeconds: 20, sets: 5)

    func seconds(_ phase: HoldPhase) -> Int {
        switch phase {
        case .inhale, .exhale: return breatheSeconds
        case .hold:            return holdSeconds
        }
    }

    var setSeconds:   Int { breatheSeconds * 2 + holdSeconds }
    var totalSeconds: Int { setSeconds * sets }

    /// "20s × 5" — the shape of the session in the fewest characters that still
    /// say both numbers.
    var label: String { "\(holdSeconds)s × \(sets)" }

    /// Time under hold across the whole session, which is the number that
    /// actually describes the dose.
    var totalHoldSeconds: Int { holdSeconds * sets }
}
