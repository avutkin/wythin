import Foundation

/// One axis reading.
///
/// An axis that cannot be computed says why rather than showing a number it
/// does not have. A fabricated zero is worse than a blank: it is indistinguishable
/// from a real result, and it teaches the wearer to distrust the ones that are real.
enum AxisValue: Equatable {
    case score(Int, word: String)
    case unavailable(reason: String)
}

/// The exercise scoring model: one descriptive magnitude and three directional
/// axes that are never averaged together.
///
/// Averaging is what broke the old model. Collapsing nine restorative metrics
/// into one mean guaranteed that a hard session — heart rate up, variability
/// down, exactly as intended — scored as a bad one. Load carries the size of
/// the stimulus here, which is what frees all three axes to point the same way:
/// higher is better on every one.
struct ExerciseResponse {

    let load:        Int
    let suppression: AxisValue
    let recovery:    AxisValue
    let efficiency:  AxisValue
    let domainSplit: [IntensityDomain: TimeInterval]

    /// Sessions of the same subtype needed before a comparison means anything.
    static let minimumHistory = 3

    // MARK: - Scoring

    /// Position of `value` within `history`, as 0…100 where higher is better.
    ///
    /// Percentile against the wearer's own history rather than an absolute
    /// scale, because none of these quantities has a meaningful absolute range —
    /// a VSI slope of −0.24 is only interpretable next to your own others.
    static func percentileScore(value: Double,
                                history: [Double],
                                lowerIsBetter: Bool) -> Int? {
        guard history.count >= minimumHistory else { return nil }
        let better = history.filter { lowerIsBetter ? value < $0 : value > $0 }.count
        let equal  = history.filter { $0 == value }.count
        let pct = (Double(better) + 0.5 * Double(equal)) / Double(history.count) * 100
        return Int(min(max(pct, 0), 100).rounded())
    }

    /// Suppression: autonomic cost per unit of internal (heart-rate) work.
    static func suppression(slope: Double?, history: [Double]) -> AxisValue {
        guard let slope else { return .unavailable(reason: "no fit") }
        guard let score = percentileScore(value: slope, history: history,
                                          lowerIsBetter: false) else {
            return .unavailable(reason: "\(history.count + 1) of \(minimumHistory)")
        }
        return .score(score, word: word(for: score))
    }

    /// Efficiency: the same question against *external mechanical* work.
    ///
    /// Deliberately never falls back to heart rate. Suppression already
    /// normalises by HR, so a fallback would make the two axes the same number
    /// printed twice. Where there is no mechanical signal — lifting, yoga,
    /// swimming — this stays empty until pace or power arrives.
    ///
    /// The two absences are distinct and must read differently: no denominator
    /// at all, versus not enough history to compare against.
    static func efficiency(slope: Double?,
                           history: [Double],
                           hasExternalSignal: Bool) -> AxisValue {
        guard hasExternalSignal, let slope else {
            return .unavailable(reason: "no ext. signal")
        }
        guard let score = percentileScore(value: slope, history: history,
                                          lowerIsBetter: false) else {
            return .unavailable(reason: "\(history.count + 1) of \(minimumHistory)")
        }
        return .score(score, word: word(for: score))
    }

    /// Phase 1 Recovery: vagal reactivation from the existing 10-minute
    /// after-window, as a percentage of pre-session DC.
    ///
    /// One checkpoint of the seven the full cascade will carry, so it always
    /// reads provisional. Published comparators for context: yoga ≈ 48 %,
    /// resistance ≈ 28 %, aerobic ≈ 21 %.
    static func reactivationScore(dcAfter: Double?, dcPre: Double?) -> AxisValue {
        guard let after = dcAfter, let pre = dcPre, pre > 0 else {
            return .unavailable(reason: "no baseline")
        }
        let pct = min(max(after / pre * 100, 0), 100)
        return .score(Int(pct.rounded()), word: "provisional · 1 of 7")
    }

    /// Plain-language read of a cost score.
    ///
    /// Never "poor" and never "bad" — see the spec's copy rules. The vocabulary
    /// is about expense, not worth, because a costly session is information
    /// about the day, not a verdict on the effort.
    static func word(for score: Int) -> String {
        switch score {
        case 80...:   return "cheap"
        case 60..<80: return "better than usual"
        case 40..<60: return "typical"
        case 20..<40: return "costlier than usual"
        default:      return "costly"
        }
    }
}
