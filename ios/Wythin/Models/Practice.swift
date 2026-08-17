import SwiftUI

// MARK: - Practice content domain
//
// Static, in-app content — NOT SwiftData records, so no @Model and no schema
// entry. Each Practice maps to an existing `ActivityType` (+ optional subtype)
// so logging reuses the whole ActivityLog pipeline.

enum PracticeCategory: String, CaseIterable, Identifiable {
    case breathwork, meditation, movement, recovery
    var id: String { rawValue }
    var label: String {
        switch self {
        case .breathwork: return "Breathwork"
        case .meditation: return "Meditation"
        case .movement:   return "Movement"
        case .recovery:   return "Recovery"
        }
    }
}

/// The state a person is trying to reach. This — not the modality — is what the
/// hub filters on, because "what do I need right now" is the question someone
/// opens the app with. Membership is many-to-many; a practice's first state is
/// its primary one.
enum PracticeState: String, CaseIterable, Identifiable {
    case focus, stress, anxiety, sleep
    var id: String { rawValue }

    var label: String {
        switch self {
        case .focus:   return "Sharpen Focus"
        case .stress:  return "Manage Stress"
        case .anxiety: return "Reduce Anxiety"
        case .sleep:   return "Improve Sleep"
        }
    }

    /// Short form for the hub's capsule bar, where the full label won't fit.
    var chip: String {
        switch self {
        case .focus:   return "Focus"
        case .stress:  return "Stress"
        case .anxiety: return "Anxiety"
        case .sleep:   return "Sleep"
        }
    }

    var icon: String {
        switch self {
        case .focus:   return "target"
        case .stress:  return "gauge.with.dots.needle.33percent"
        case .anxiety: return "wind"
        case .sleep:   return "moon.zzz"
        }
    }
}

enum BiofeedbackMode: Equatable, Hashable { case resonance, workout }

enum PracticeKind: Equatable, Hashable {
    case content                        // browse + Log it
    case biofeedback(BiofeedbackMode)   // live session (resonance pacer / workout feedback)
    case pacer(BreathPattern)           // guided breath session on a fixed pattern
    case holdTrainer(HoldProtocol)      // set-based breath-hold session
}

/// Local art token — an optional SF Symbol over a two-stop gradient. There is no
/// remote image loading in the app, so every practice paints from this. A nil
/// symbol leaves the gradient bare, for art that is the colour field itself.
struct PracticeArt: Hashable {
    let symbol:   String?      // SF Symbol name, or nil for a bare gradient
    let hexStops: [String]     // two hex colours → LinearGradient via Color(hex:)

    init(symbol: String? = nil, hexStops: [String]) {
        self.symbol   = symbol
        self.hexStops = hexStops
    }

    var gradient: LinearGradient {
        LinearGradient(colors: hexStops.map { Color(hex: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The glyph laid over the gradient — nothing at all when the art is meant to
    /// be the colour field on its own.
    @ViewBuilder
    func glyph(size: CGFloat, weight: Font.Weight = .light, opacity: Double = 0.9) -> some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white.opacity(opacity))
        }
    }
}

/// A published study backing a practice.
///
/// Every field here is transcribed from the real paper — these are shown to the
/// user as evidence, so nothing in this type may be approximated or invented, and
/// `finding` must say what the study actually found rather than what would sell
/// the practice best.
struct PracticeEvidence: Identifiable, Hashable {
    let doi:     String        // also the identity
    let title:   String
    let authors: String        // "Balban et al."
    let journal: String
    let year:    Int
    let finding: String        // one sentence, faithful to the result
    let mark:    String        // 3-letter monogram for the source badge
    let tint:    String        // badge hex

    var id: String { doi }
    var url: URL { URL(string: "https://doi.org/\(doi)")! }
}

struct Practice: Identifiable, Hashable {
    let id:                  String
    let title:               String
    let subtitle:            String
    let category:            PracticeCategory
    let states:              [PracticeState] // non-empty; first is primary
    let activityType:        ActivityType   // reuse the logging enum
    let subtype:             String?        // must be a member of activityType.subtypes
    let defaultDurationMins: Int
    /// Metronome tempo this practice ships with. Pace is counted in beats, so the
    /// tempo is what fixes a phase in seconds — a 5.5-second phase is only
    /// reachable as 11 beats at 120 BPM.
    let defaultBPM:          Int
    let description:         String
    /// Two or three plain sentences on the mechanism — what the practice does to
    /// the body, and why the shape of it matters.
    let howItWorks:          [String]
    let evidence:            [PracticeEvidence]
    let tags:                [String]
    let art:                 PracticeArt
    let kind:                PracticeKind

    /// The featured practice, shown with a ★ above the grid.
    var isStarred: Bool { kind == .biofeedback(.resonance) }

    var isBiofeedback: Bool {
        if case .biofeedback = kind { return true }
        return false
    }

    /// The breath pattern this practice paces, if it is a guided pacer.
    var breathPattern: BreathPattern? {
        if case .pacer(let pattern) = kind { return pattern }
        return nil
    }

    /// The hold course this practice runs, if it is a hold trainer.
    var holdProtocol: HoldProtocol? {
        if case .holdTrainer(let plan) = kind { return plan }
        return nil
    }

    /// The state this practice exists for, as opposed to the ones it also serves.
    var primaryState: PracticeState? { states.first }
}
