import Foundation

/// The yoga rule (research doc §4): one "Yoga" label spans yin to power
/// vinyasa, so the session classifies ITSELF from measurement — the label is
/// only the prior. Scoring then splits into two channels that are never
/// combined: training load (legitimately ~0 for yin) and regulation credit
/// (the vagal rebound the practice exists to produce).
enum MindBodyClass: String {
    case restorative   // near-rest: the regulation channel is the story
    case mixed         // flow + floor: both channels, each for its minutes
    case workout       // vinyasa end: the exercise model applies
}

enum MindBodyResponse {

    /// Subtypes whose sessions get the mind-body read when measurement agrees.
    static let mindBodySubtypes: Set<String> = ["Yoga", "Pilates", "Stretching"]

    /// Fraction of the session at elevated effort at or above which the
    /// measurement calls it a workout, and at or below which restorative.
    /// The strap-available proxy for the research's "time above 40% HRR" is
    /// time in Z2+ (≥60% reserve) — conservative: it under-calls workouts,
    /// never over-calls them.
    static let workoutFraction:     Double = 0.50
    static let restorativeFraction: Double = 0.15

    /// Which class the measurement supports.
    ///
    /// `vagalRose` is the strongest single vote: DC rising while moving is the
    /// app's best measured evidence a session was restorative — the flag that
    /// used to be only a refusal to score suppression becomes the classifier's
    /// anchor (per the research: "the pieces are all built; they're just not
    /// connected to classification").
    static func classify(elevatedSeconds: Double,
                         durationSeconds: Double,
                         vagalRose: Bool,
                         deltaRMSSDPct: Double?) -> MindBodyClass {
        guard durationSeconds > 0 else { return .restorative }
        let fraction = elevatedSeconds / durationSeconds

        if vagalRose && fraction < workoutFraction { return .restorative }
        if fraction >= workoutFraction { return .workout }
        if fraction <= restorativeFraction { return .restorative }
        // The tiebreak for the middle band: an immediate vagal rebound is the
        // restorative signature; suppression after stopping is the workout one.
        if let delta = deltaRMSSDPct {
            return delta >= 0 ? .restorative : .mixed
        }
        return .mixed
    }

    // MARK: Regulation credit — Channel B

    /// ΔRMSSD pre→post at which the credit tops out / bottoms.
    ///
    /// Measured from the AFTER window (spontaneous breathing) against BEFORE,
    /// never in-session: RMSSD during paced slow breathing is mechanically
    /// inflated and is not a parasympathetic measure there.
    static let fullRebound:  Double = 40    // +40% post vs pre → 100
    static let fullSuppress: Double = -20   // −20% → 0

    static func regulationScore(beforeRMSSD: Double?, afterRMSSD: Double?) -> Int? {
        guard let before = beforeRMSSD, before > 0, let after = afterRMSSD else { return nil }
        let deltaPct = (after - before) / before * 100
        return SessionIndices.ramp(deltaPct, best: fullRebound, worst: fullSuppress)
    }

    static func index(beforeRMSSD: Double?, afterRMSSD: Double?) -> ScoredIndex? {
        guard let value = regulationScore(beforeRMSSD: beforeRMSSD, afterRMSSD: afterRMSSD),
              let before = beforeRMSSD, let after = afterRMSSD else { return nil }
        let deltaPct = Int(((after - before) / before * 100).rounded())
        return ScoredIndex(
            name: "Regulation",
            value: value,
            verdict: value >= IndexBand.keepAbove ? "settled you"
                   : value >= IndexBand.actBelow  ? "left you level"
                                                  : "left you activated",
            detail: "\(deltaPct >= 0 ? "+" : "")\(deltaPct)% calm after")
    }
}

extension ActivityLog {

    /// Whether this session gets the mind-body read.
    var isMindBody: Bool {
        activitySubtype.map { MindBodyResponse.mindBodySubtypes.contains($0) } ?? false
    }

    /// The measured class, from fields already on disk. Zone seconds stand in
    /// for the elevated-time feature; breath rate and transition rate join
    /// when their fields exist.
    var mindBodyClass: MindBodyClass? {
        guard isMindBody, let end = endedAt else { return nil }
        let elevated = [zone2Sec, zone3Sec, zone4Sec, zone5Sec]
            .compactMap { $0 }.reduce(0, +)
        let deltaPct: Double? = {
            guard let b = beforeRMSSD.map(Double.init), b > 0,
                  let a = afterRMSSD.map(Double.init) else { return nil }
            return (a - b) / b * 100
        }()
        return MindBodyResponse.classify(elevatedSeconds: elevated,
                                         durationSeconds: end.timeIntervalSince(startedAt),
                                         vagalRose: vagalRoseDuring,
                                         deltaRMSSDPct: deltaPct)
    }

    /// Channel B for the row: the vagal rebound the practice exists to produce.
    var regulationIndex: ScoredIndex? {
        guard isMindBody else { return nil }
        return MindBodyResponse.index(beforeRMSSD: beforeRMSSD.map(Double.init),
                                      afterRMSSD: afterRMSSD.map(Double.init))
    }
}
