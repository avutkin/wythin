import SwiftUI

// MARK: - Practice content domain
//
// Static, in-app content (teacher-led practices) — NOT SwiftData records, so no
// @Model and no schema entry. Each Practice maps to an existing `ActivityType`
// (+ optional subtype) so logging reuses the whole ActivityLog pipeline.

struct Teacher: Identifiable, Hashable {
    let id:    String          // stable slug, e.g. "mara-quinn"
    let name:  String
    let title: String          // e.g. "Breathwork Guide"
    let bio:   String
    let art:   PracticeArt
}

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
}

/// Local art token — an SF Symbol over a two-stop gradient. There is no remote
/// image loading in the app, so every practice/teacher paints from this.
struct PracticeArt: Hashable {
    let symbol:   String       // SF Symbol name
    let hexStops: [String]     // two hex colours → LinearGradient via Color(hex:)

    var gradient: LinearGradient {
        LinearGradient(colors: hexStops.map { Color(hex: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Practice: Identifiable, Hashable {
    let id:                  String
    let title:               String
    let subtitle:            String
    let teacherID:           String
    let category:            PracticeCategory
    let states:              [PracticeState] // non-empty; first is primary
    let activityType:        ActivityType   // reuse the logging enum
    let subtype:             String?        // must be a member of activityType.subtypes
    let defaultDurationMins: Int
    let description:         String
    let tags:                [String]
    let art:                 PracticeArt
    let kind:                PracticeKind

    /// Resonance is the featured biofeedback practice — shown with a ★.
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

    /// The state this practice exists for, as opposed to the ones it also serves.
    var primaryState: PracticeState? { states.first }
}
