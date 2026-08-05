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

    /// "6-6-6-6", for the practice copy and the session readout.
    var label: String { "\(inhale)-\(holdIn)-\(exhale)-\(holdOut)" }
}
