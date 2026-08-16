import Foundation

/// The 0–100 headline score for an exercise session.
///
/// Composed from the three axes **and never from Load**. That is the whole
/// design of it: Suppression, Recovery and Efficiency all measure how well the
/// work was absorbed and how economically it was done, so a longer or harder
/// session cannot inflate the number by being longer or harder. The score
/// answers "how well did this land?", and Load — displayed separately —
/// answers "how big was it?".
///
/// If Load fed in, the crown would go to whoever went hardest, which is how a
/// training app teaches people to overreach.
enum ExerciseOverallScore {

    /// At or above this, the session earns a crown.
    ///
    /// 85 on a percentile-derived scale is roughly a top-sixth session against
    /// your own history — frequent enough to stay motivating, rare enough to
    /// still mean something.
    static let crownThreshold = 85

    /// Recovery leads because it is the one axis available from the first
    /// session, and because absorbing the work is the point of doing it.
    static let recoveryWeight:    Double = 0.45
    static let suppressionWeight: Double = 0.35
    static let efficiencyWeight:  Double = 0.20

    /// Below this many contributing axes the score is labelled provisional
    /// rather than presented as settled.
    static let firmComponents = 2

    /// Combines whichever axes resolved into a single 0–100, renormalising over
    /// the ones present. Returns `.unavailable` when none did.
    static func compute(suppression: AxisValue,
                        recovery: AxisValue,
                        efficiency: AxisValue) -> AxisValue {

        func value(_ axis: AxisValue) -> Int? {
            if case let .score(v, _) = axis { return v }
            return nil
        }

        let parts: [(Int?, Double, String)] = [
            (value(recovery),    recoveryWeight,    "bounce-back"),
            (value(suppression), suppressionWeight, "brake release"),
            (value(efficiency),  efficiencyWeight,  "efficiency"),
        ]
        let present = parts.compactMap { v, w, n in v.map { (Double($0), w, n) } }
        guard !present.isEmpty else { return .unavailable(reason: "not enough signal") }

        let totalWeight = present.reduce(0) { $0 + $1.1 }
        let weighted    = present.reduce(0) { $0 + $1.0 * $1.1 }
        let score       = Int((weighted / totalWeight).rounded())

        // A single-axis caption names the axis it rests on. It used to say
        // "recovery alone" whichever axis survived, so a 0 from brake release
        // sat beside a 92 readiness captioned as a recovery problem.
        let word = present.count >= firmComponents
            ? caption(for: score, components: present.count)
            : "based on \(present[0].2) alone so far"
        return .score(score, word: word)
    }

    /// Whether a score earns the crown. Provisional scores do not — a crown
    /// awarded on one axis and then withdrawn tomorrow is worse than no crown.
    static func earnsCrown(_ axis: AxisValue) -> Bool {
        guard case let .score(score, word) = axis else { return false }
        // Keyed off the caption vocabulary, which is why the provisional wording
        // and this check must change together.
        return score >= crownThreshold && !word.contains("alone so far")
    }

    /// Plain-language read.
    ///
    /// The vocabulary describes how the session landed, never how hard it was,
    /// and never scolds — the low end is "a lot to absorb", which is a fact
    /// about the day rather than a verdict on the effort.
    static func caption(for score: Int, components: Int) -> String {
        // "1 of 3" is internal bookkeeping. Say which axis the number rests on.
        guard components >= firmComponents else { return "based on recovery alone so far" }
        switch score {
        case crownThreshold...: return "outstanding session"
        case 70..<crownThreshold: return "well absorbed"
        case 55..<70:  return "solid session"
        case 40..<55:  return "steady session"
        case 25..<40:  return "took some absorbing"
        default:       return "a lot to absorb"
        }
    }
}
