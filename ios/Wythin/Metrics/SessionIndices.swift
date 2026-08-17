import Foundation

/// Where a 0–100 index sits, and what the owner should do about it.
///
/// Three bands, not five. A finer scale invites reading movement between
/// neighbouring bands as a result when it is usually noise, and the whole point
/// of the band is to answer one question: is this worth acting on?
enum IndexBand {

    /// Below `actBelow` — the weak read, and the one the recommendation speaks to.
    case act

    /// Ordinary. Not a failure, not a win; the word for it is "fine".
    case improve

    /// Strong enough that repeating whatever produced it is the advice.
    case keep

    static let actBelow  = 45
    static let keepAbove = 70

    static func of(_ value: Int) -> IndexBand {
        if value < actBelow  { return .act }
        if value < keepAbove { return .improve }
        return .keep
    }

    /// The legend under the grid. Kept here so the copy and the thresholds
    /// cannot drift apart.
    var legend: String {
        switch self {
        case .act:     return "under \(IndexBand.actBelow) — act on it"
        case .improve: return "\(IndexBand.actBelow)–\(IndexBand.keepAbove - 1) — room to improve"
        case .keep:    return "\(IndexBand.keepAbove)+ — keep doing this"
        }
    }
}

/// One scored 0–100 reading, with the words that go under it.
///
/// `verdict` says what the number means in one phrase; `detail` carries the
/// measurement it came from, so the index stays checkable rather than being a
/// number the app asserts.
struct ScoredIndex: Equatable {
    let name: String
    let value: Int
    let verdict: String
    let detail: String

    var band: IndexBand { .of(value) }
}

/// A quantity with no good or bad direction.
///
/// Load and peak heart rate belong here. Scoring them would mean telling the
/// owner that a heavier session beat a lighter one, which is not a claim the
/// measurement supports — and a grid of eight scores when only six have a
/// direction implies six verdicts the app cannot defend.
struct UngradedDose: Equatable {
    let name: String
    let value: String
    let caption: String
}

// MARK: - The shared ramp

enum SessionIndices {

    /// Linear 0–100 between two anchors, clamped at both ends.
    ///
    /// `best` may be numerically lower than `worst` — for a duration or a drift,
    /// smaller is better — so the direction comes from the arguments rather
    /// than from a flag the caller has to remember.
    static func ramp(_ value: Double, best: Double, worst: Double) -> Int {
        guard best != worst else { return 50 }
        let fraction = (worst - value) / (worst - best)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}

// MARK: - Warm-up speed

/// How quickly the vagal brake came off at the start of the session.
///
/// This is responsiveness, not effort. A hard session can mobilise slowly and
/// an easy one quickly, so the index must never be read as a grade for how much
/// work was done — the copy under it says exactly that.
enum MobilisationIndex {

    static let displayName = "Warm-up speed"

    /// Anchors are fixed rather than personal, because time-to-half-range is
    /// comparable across people in a way that most of these are not.
    static let fastSeconds: Double = 25
    static let slowSeconds: Double = 90

    static func score(secondsToHalfRange: Double?) -> Int? {
        guard let seconds = secondsToHalfRange, seconds > 0 else { return nil }
        return SessionIndices.ramp(seconds, best: fastSeconds, worst: slowSeconds)
    }

    static func index(secondsToHalfRange: Double?) -> ScoredIndex? {
        guard let value = score(secondsToHalfRange: secondsToHalfRange),
              let seconds = secondsToHalfRange else { return nil }
        return ScoredIndex(
            name: displayName,
            value: value,
            verdict: value >= IndexBand.keepAbove ? "switched on fast"
                   : value >= IndexBand.actBelow  ? "took its time"
                                                  : "slow to switch on",
            detail: "\(Int(seconds.rounded())) s")
    }
}

// MARK: - Brake release

/// How far the calm brake had to come off for the work that was done.
///
/// Named for the mechanism rather than for its cost, so it stays distinct from
/// Efficiency sitting beside it: this one is depth, Efficiency is price per
/// beat. A high score means the work was performed without giving up much brake.
enum BrakeReleaseIndex {

    static let displayName = "Brake release"

    static func index(score: Int?, troughDC: Double?) -> ScoredIndex? {
        guard let score else { return nil }
        return ScoredIndex(
            name: displayName,
            value: score,
            verdict: score >= IndexBand.keepAbove ? "held on well"
                   : score >= IndexBand.actBelow  ? "came off deeper"
                                                  : "came off very deep",
            detail: troughDC.map { String(format: "floor %.1f ms", $0) } ?? "")
    }
}

// MARK: - Steadiness

/// Heart-rate creep in the second half of the session at the same output.
///
/// Drift is normal; a lot of it says the session outran what the owner could
/// hold, which is a pacing finding rather than a fitness one.
enum SteadinessIndex {

    static let displayName = "Steadiness"

    /// Anchored on the endurance literature's decoupling convention, where
    /// roughly 5% heart-rate drift at the same output is the line between
    /// holding a session and outrunning it. That puts 5% just past the middle
    /// of the scale rather than at either end.
    static let steadyDriftPercent:   Double = 1
    static let driftingDriftPercent: Double = 10

    static func score(driftPercent: Double?) -> Int? {
        guard let drift = driftPercent else { return nil }
        return SessionIndices.ramp(drift, best: steadyDriftPercent, worst: driftingDriftPercent)
    }

    static func index(driftPercent: Double?) -> ScoredIndex? {
        guard let value = score(driftPercent: driftPercent),
              let drift = driftPercent else { return nil }
        return ScoredIndex(
            name: displayName,
            value: value,
            verdict: value >= IndexBand.keepAbove ? "held its pace"
                   : value >= IndexBand.actBelow  ? "drifted late on"
                                                  : "drifted a lot",
            detail: String(format: "%.1f%%", drift))
    }
}

// MARK: - Bounce-back

/// How fast the system came back, from three readings scored separately first.
///
/// They are scored to 0–100 individually and only then averaged, because they
/// arrive in different units — beats, minutes and a bare ratio — and averaging
/// those directly would weight whichever happens to have the largest numbers.
enum BounceBackIndex {

    static let displayName = "Bounce-back"

    /// Decoupling has no published norm — it is our own construct — so it is
    /// scored against the owner's own history and contributes nothing until
    /// there is enough of it.
    static let minimumHistoryForDecoupling = 5

    static func decouplingScore(_ ratio: Double?, personalMean: Double?) -> Int? {
        guard let ratio, let mean = personalMean, mean > 0 else { return nil }
        // Tighter than usual scores high: half the personal mean is 100, double it is 0.
        return SessionIndices.ramp(ratio, best: mean * 0.5, worst: mean * 2)
    }

    static func score(hrr60Bpm: Double?,
                      halfRecoveryMinutes: Double?,
                      decoupling: Double?,
                      decouplingMean: Double?,
                      decouplingHistoryCount: Int) -> Int? {

        let parts: [Int?] = [
            HeartRateRecovery.score(hrr60: hrr60Bpm),
            halfRecoveryMinutes.map {
                SessionIndices.ramp($0, best: RecoveryTiming.fastMinutes,
                                        worst: RecoveryTiming.slowMinutes)
            },
            decouplingHistoryCount >= minimumHistoryForDecoupling
                ? decouplingScore(decoupling, personalMean: decouplingMean)
                : nil,
        ]
        let present = parts.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return Int((Double(present.reduce(0, +)) / Double(present.count)).rounded())
    }

    static func index(value: Int?, halfRecoveryMinutes: Double?) -> ScoredIndex? {
        guard let value else { return nil }
        return ScoredIndex(
            name: displayName,
            value: value,
            verdict: value >= IndexBand.keepAbove ? "came back fast"
                   : value >= IndexBand.actBelow  ? "came back slowly"
                                                  : "still not back",
            detail: halfRecoveryMinutes.map { String(format: "halfway in %.1f min", $0) } ?? "")
    }
}

// MARK: - Mobilized (interim)

/// How far the system rose to meet the load — interim, from window fields.
/// Upgrades to true onset speed (tHalf) when the session series is stored.
enum MobilizedIndex {
    static let displayName = "Mobilized"
    static let smallRise: Double = 15    // the classification floor → 0
    static let fullRise:  Double = 60    // a full mobilization → 100

    static func score(pulseRise: Double?) -> Int? {
        guard let rise = pulseRise, rise > 0 else { return nil }
        return SessionIndices.ramp(rise, best: fullRise, worst: smallRise)
    }

    static func index(pulseRise: Double?) -> ScoredIndex? {
        guard let value = score(pulseRise: pulseRise), let rise = pulseRise else { return nil }
        return ScoredIndex(name: displayName, value: value,
            verdict: value >= IndexBand.keepAbove ? "rose to meet it"
                   : value >= IndexBand.actBelow  ? "partly mobilized"
                                                  : "barely mobilized",
            detail: "+\(Int(rise.rounded())) bpm over resting")
    }
}

// MARK: - Sustained (interim)

/// Whether the heart's effort and the system it taxed told the same story:
/// total-variation overlap between the zone and domain time-distributions.
/// The alpha-1 stability half joins at 60% weight when the series is stored.
enum SustainedIndex {
    static let displayName = "Sustained"

    static func score(zoneModerate: Double, zoneHeavy: Double, zoneSevere: Double,
                      domModerate: Double, domHeavy: Double, domSevere: Double) -> Int? {
        let zTotal = zoneModerate + zoneHeavy + zoneSevere
        let dTotal = domModerate + domHeavy + domSevere
        guard zTotal > 0, dTotal > 0 else { return nil }
        let z = [zoneModerate/zTotal, zoneHeavy/zTotal, zoneSevere/zTotal]
        let d = [domModerate/dTotal, domHeavy/dTotal, domSevere/dTotal]
        let tv = zip(z, d).reduce(0.0) { $0 + abs($1.0 - $1.1) } / 2
        return Int(((1 - tv) * 100).rounded())
    }

    static func index(value: Int?) -> ScoredIndex? {
        guard let value else { return nil }
        return ScoredIndex(name: displayName, value: value,
            verdict: value >= IndexBand.keepAbove ? "systems agree"
                   : value >= IndexBand.actBelow  ? "partly aligned"
                                                  : "systems disagree",
            detail: "zones vs taxed system")
    }
}

// MARK: - Overall from sections

extension ExerciseOverallScore {
    /// The five-section composite: performance sections only, Ready excluded,
    /// weights printed in the detail so the number stays checkable.
    static let sectionWeights: [(String, Double)] =
        [("Recovery", 0.40), ("Sustained", 0.30), ("Cost", 0.20), ("Mobilized", 0.10)]

    static func composeSections(recovery: Int?, sustained: Int?,
                                cost: Int?, mobilized: Int?) -> AxisValue {
        let parts: [(Int?, Double, String)] = [
            (recovery, 0.40, "recovery"), (sustained, 0.30, "sustained"),
            (cost, 0.20, "cost"), (mobilized, 0.10, "mobilized"),
        ]
        let present = parts.compactMap { v, w, n in v.map { (Double($0), w, n) } }
        guard present.count >= firmComponents else {
            return present.first.map { .score(Int($0.0), word: "based on \($0.2) alone so far") }
                ?? .unavailable(reason: "not enough signal")
        }
        let total = present.reduce(0) { $0 + $1.1 }
        let score = Int((present.reduce(0) { $0 + $1.0 * $1.1 } / total).rounded())
        return .score(score, word: caption(for: score, components: present.count))
    }
}

// MARK: - What to do next time

/// One action, derived from the weakest scored index.
///
/// Deterministic on purpose. The coach card this replaces generated text that
/// could contradict the score beside it; a phrase chosen by the lowest number
/// cannot, and it can be tested.
enum SessionRecommendation {

    /// Nothing worth saying until at least this many indices resolved — a
    /// "weakest" of one is just the only one.
    static let minimumIndices = 3

    struct Advice: Equatable {
        /// Leads the card, in bold: the thing to actually do.
        let action: String
        /// Why, naming the index and its value.
        let because: String
    }

    static func advice(for indices: [ScoredIndex]) -> Advice? {
        guard indices.count >= minimumIndices,
              let weakest = indices.min(by: { $0.value < $1.value }) else { return nil }

        // Everything strong is itself a finding, and deserves different words
        // from a session with a weak read in it.
        if weakest.band == .keep {
            return Advice(
                action: "Repeat this session as it was.",
                because: "Nothing came in below \(weakest.value) — your weakest read today is "
                       + "\(weakest.name.lowercased()), and it is still in the strong band.")
        }

        return Advice(
            action: action(for: weakest.name),
            because: "\(weakest.name) is your one weak read at \(weakest.value) — "
                   + "\(weakest.verdict), while everything else came in at or above normal.")
    }

    /// The action is tied to the index it would move. A general "train less"
    /// would be true of every weak read and therefore useless on all of them.
    static func action(for indexName: String) -> String {
        switch indexName {
        case BrakeReleaseIndex.displayName:
            return "Do this next time: walk easily for two minutes between sets."
        case MobilisationIndex.displayName:
            return "Do this next time: add five minutes of easy warm-up before the first hard effort."
        case BounceBackIndex.displayName:
            return "Do this next time: keep the last ten minutes easy instead of finishing hard."
        case SteadinessIndex.displayName:
            return "Do this next time: start the session slower and hold that pace to the end."
        case "Efficiency":
            return "Do this next time: keep the load the same and lengthen the rests."
        case "Readiness":
            return "Do this next time: train this session on a day you have slept well."
        default:
            return "Do this next time: repeat the session and see whether the reading holds."
        }
    }
}
