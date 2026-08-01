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

    /// Scored as the mean benefit-signed change across the nine metrics.
    case restorative
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
             .thermal, .drinks, .work, .custom:
            return .restorative
        }
    }
}
