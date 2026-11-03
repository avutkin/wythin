import Foundation

/// Which scoring model an activity uses.
///
/// The nine-metric benefit delta asks "did this settle you?", which is the
/// right question for a meditation and the wrong one for a set of squats.
/// Exercise raises heart rate and suppresses variability *by design*, so under
/// the restorative model a hard session posts a large negative number by
/// construction — the app reads its owner's best training as their worst day.
///
/// The two classes exist so that never happens again, and so restorative
/// activities keep their original code path untouched rather than being
/// special-cased inside a model built for exercise.
enum ActivityClass {

    /// Load with expected vagal withdrawal. Scored as Load plus three
    /// independent axes — Suppression, Recovery, Efficiency — which are never
    /// averaged together.
    case activating

    /// Scored as the mean benefit-signed change across the named metrics.
    case restorative
}

extension ActivityClass {

    /// Mean heart rate this far above the pre-session level counts as real
    /// activation.
    ///
    /// Fifteen beats is comfortably clear of what posture, a deep breath or a
    /// warm room will do, and comfortably below anything anyone would call
    /// exercise. Below it the session gets the restorative reading; at or above
    /// it, the activation model and the fuller recovery analysis.
    static let activatingHRRise: Double = 15

    /// Which model a session gets, decided by what the heart actually did
    /// rather than by the tile it was logged under.
    ///
    /// The label is a guess made before the session; the heart rate is a
    /// measurement made during it. A brisk vinyasa logged as Yoga raises the
    /// pulse and deserves the recovery analysis; a restorative session logged
    /// as Exercise does not. Where there is no measurement — an entry with no
    /// strap data — the type is the only evidence available and stands in.
    static func measured(beforeHR: Double?, duringHR: Double?,
                         fallback: ActivityClass) -> ActivityClass {
        guard let beforeHR, let duringHR else { return fallback }
        return (duringHR - beforeHR) >= activatingHRRise ? .activating : .restorative
    }
}

extension ActivityType {

    var activityClass: ActivityClass {
        switch self {
        case .exercise, .walk:
            // Walk has merged into Exercise (its subtypes moved across), but the
            // case survives for entries already in flight and must classify the
            // same way — a walk is a low-load session of the same physiology.
            return .activating

        case .meditation, .breathwork, .meal, .nap,
             .thermal, .drinks, .work, .sleep, .custom:
            // Sleep is restorative by construction. It must never reach the
            // activating path, which would hand it a TRIMP load, a suppression
            // axis and workout-shaped expectations — the same category error
            // the research report flags for yin yoga, an order of magnitude
            // longer.
            return .restorative
        }
    }
}
