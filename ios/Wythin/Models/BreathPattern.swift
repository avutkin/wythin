import Foundation

// MARK: - Breath patterns
//
// A four-part breath, in whole seconds per phase. Whole seconds because the
// metronome runs at 60 BPM — one beat is one second — so a phase length is also
// its beat count, and the accented beat that opens a phase always lands exactly
// on the phase change.

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

    var next: BreathPhase {
        BreathPhase(rawValue: (rawValue + 1) % BreathPhase.allCases.count)!
    }
}

struct BreathPattern: Equatable, Hashable {
    let inhale:  Int
    let holdIn:  Int
    let exhale:  Int
    let holdOut: Int

    /// Six in, six held, six out, six held — a 24-second cycle, 2.5 breaths/min.
    static let box = BreathPattern(inhale: 6, holdIn: 6, exhale: 6, holdOut: 6)

    func seconds(_ phase: BreathPhase) -> Int {
        switch phase {
        case .inhale:  return inhale
        case .holdIn:  return holdIn
        case .exhale:  return exhale
        case .holdOut: return holdOut
        }
    }

    var cycleSeconds: Int { inhale + holdIn + exhale + holdOut }

    /// "6-6-6-6", for the practice copy and the session header.
    var label: String { "\(inhale)-\(holdIn)-\(exhale)-\(holdOut)" }
}
