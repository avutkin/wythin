import Foundation

/// How well the session was absorbed, from every recovery checkpoint that has
/// arrived — weighted, renormalised over the ones present, and labelled with
/// how complete the picture is.
///
/// **Why a composite.** Recovery does not arrive at one moment. Heart rate is
/// most of the way home inside a minute; the vagal brake reactivates over
/// minutes to hours (Stanley, Peake & Buchheit, *Sports Medicine* 2013). A
/// single-measure score therefore reports whichever half of recovery it
/// happened to be built from, and calls it the whole thing.
///
/// The failure this replaces was exactly that. One recorded session had heart
/// rate back within four minutes and a vagal brake still short of halfway at
/// thirty-four; the section scored **0** — because the brake's zero was the
/// only checkpoint that resolved, and a lone checkpoint became the section.
/// The screen printed 0 directly above a chart of a fast return.
///
/// Two rules follow from that, and both are pinned by tests:
///
/// 1. **A checkpoint that never arrived is absent, not zero.** Only a measured
///    failure scores low. The weights renormalise over what is present.
/// 2. **No score from a single checkpoint.** Below `minimumComponents` the
///    section shows its checkpoints and no number, the same rule
///    `ExerciseOverallScore.firmComponents` already applies one level up.
enum RecoveryIndex {

    enum Checkpoint: String, CaseIterable {
        /// Beats shed in the first minute. The strongest evidence base of the
        /// five — Cole et al., *NEJM* 1999.
        case hrr60
        /// Short-term decay constant of ln(HR) over the first thirty seconds.
        case t30
        /// RMSSD ten minutes on, as a share of the pre-session level.
        case rmssdReactivation
        /// Minutes for the vagal brake to climb halfway out of its trough.
        case vagalRebound
        /// Minutes for heart rate to fall halfway back from its peak.
        case heartRateReturn

        var displayName: String {
            switch self {
            case .hrr60:             return "Heart rate drop"
            case .t30:               return "T30"
            case .rmssdReactivation: return "Calm Power at 10 min"
            case .vagalRebound:      return "Vagal rebound"
            case .heartRateReturn:   return "Heart rate return"
            }
        }
    }

    /// Weighted by how much each checkpoint is worth as evidence, not by how
    /// early it lands.
    ///
    /// `hrr60` and `rmssdReactivation` lead because they are the two with real
    /// published comparators. The two timing channels are deliberately equal:
    /// the distance between how fast heart rate returns and how slowly the
    /// brake does is the finding this section exists to show, so tipping the
    /// scale toward either one would bury it. `t30` takes the remainder — it
    /// is largely redundant with `hrr60`, both being read from the same first
    /// half-minute, and it earns a small weight rather than a second full vote
    /// for the same measurement.
    static let weights: [Checkpoint: Double] = [
        .hrr60:             0.25,
        .rmssdReactivation: 0.25,
        .vagalRebound:      0.20,
        .heartRateReturn:   0.20,
        .t30:               0.10,
    ]

    /// Fewer than this and there is no section score — just the checkpoints.
    static let minimumComponents = 2

    struct Component: Equatable {
        let checkpoint: Checkpoint
        let score: Int
        let weight: Double
    }

    /// How much of the cascade has landed. Recovery keeps arriving for hours,
    /// so the number is shown with the honesty of a reading still in progress
    /// rather than presented as settled the moment two checkpoints exist.
    enum Firmness: Equatable {
        case provisional(present: Int, total: Int)
        case firming
        case settled

        var label: String {
            switch self {
            case let .provisional(present, total): return "provisional · \(present) of \(total)"
            case .firming:                         return "firming"
            case .settled:                         return "complete"
            }
        }
    }

    struct Result: Equatable {
        let value: Int
        let components: [Component]
        let firmness: Firmness
    }

    // MARK: - Checkpoint scoring

    /// RMSSD ten minutes after the session, as a share of the level it started
    /// from. Complete return scores 100.
    ///
    /// The floor of a quarter is provisional and labelled as such wherever it
    /// is shown: post-exercise RMSSD at ten minutes commonly sits somewhere
    /// between a fifth and two-thirds of the pre-session level depending on
    /// intensity, so a quarter is a defensible bottom rather than a measured
    /// one. It moves to personal ranking, like `t30Score` below, once there is
    /// enough history to rank against.
    static let completeReactivation: Double = 1.0
    static let floorReactivation:    Double = 0.25

    static func rmssdReactivationScore(before: Double?, after: Double?) -> Int? {
        guard let before, before > 0, let after else { return nil }
        return SessionIndices.ramp(after / before,
                                   best: completeReactivation,
                                   worst: floorReactivation)
    }

    /// T30, ranked against this person's own recent sessions — never against a
    /// fixed anchor.
    ///
    /// There is no range for T30 this app can defend the way it can defend
    /// "under 12 bpm in the first minute". Rather than invent one and dress a
    /// guess as a measurement, the checkpoint simply drops out until there is
    /// history to rank against, and the weights renormalise around its absence.
    /// Shorter is faster reactivation, so lower ranks higher.
    static func t30Score(_ seconds: Double?, peers: [Double]) -> Int? {
        guard let seconds else { return nil }
        return ReadinessScore.componentScore(
            .init(today: seconds, peers: peers, higherIsBetter: false))
    }

    // MARK: - Composition

    /// - Parameter t30Ranked: a T30 score already ranked against this person's
    ///   history at derive time, for callers with no `ModelContext` to rank
    ///   from. Preferred over `t30Peers` when present.
    static func compose(hrr60: Double?,
                        t30Seconds: Double?,
                        t30Peers: [Double],
                        rmssdBefore: Double?,
                        rmssdAfter: Double?,
                        vagal: RecoveryTiming.Outcome,
                        heartRate: RecoveryTiming.Outcome,
                        t30Ranked: Int? = nil) -> Result? {

        let scores: [Checkpoint: Int?] = [
            .hrr60:             HeartRateRecovery.score(hrr60: hrr60),
            .t30:               t30Ranked ?? t30Score(t30Seconds, peers: t30Peers),
            .rmssdReactivation: rmssdReactivationScore(before: rmssdBefore, after: rmssdAfter),
            .vagalRebound:      RecoveryTiming.score(vagal),
            .heartRateReturn:   RecoveryTiming.score(heartRate),
        ]

        // Declaration order, so the same session always lists its checkpoints
        // the same way — dictionary order is seeded per process.
        let present = Checkpoint.allCases.compactMap { c -> Component? in
            guard let score = scores[c] ?? nil, let weight = weights[c] else { return nil }
            return Component(checkpoint: c, score: score, weight: weight)
        }
        guard present.count >= minimumComponents else { return nil }

        let totalWeight = present.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let weighted = present.reduce(0.0) { $0 + Double($1.score) * $1.weight }

        let total = weights.count
        let firmness: Firmness
        switch present.count {
        case total:      firmness = .settled
        case 3...:       firmness = .firming
        default:         firmness = .provisional(present: present.count, total: total)
        }

        return Result(value: Int((weighted / totalWeight).rounded()),
                      components: present,
                      firmness: firmness)
    }
}
