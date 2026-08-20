import Foundation

// MARK: - Sections

/// The five sections a night is scored on, ordered by the strength of the
/// evidence behind them — which is also the order of their weights.
///
/// Notably absent: stage percentages. They are what every consumer product
/// leads with and they have the weakest link to outcomes of anything here,
/// measured on hardware that agrees with polysomnography at κ 0.21–0.53. A
/// number precise enough to be believed and wrong often enough to mislead does
/// not belong in a score.
enum SleepSection: String, CaseIterable, Codable {
    case timing, duration, continuity, autonomic, breathing

    /// Fixed and visible, so the overall is checkable by hand.
    var weight: Double {
        switch self {
        case .timing:     return 0.25   // SRI beat duration head-to-head
        case .duration:   return 0.25   // the one dose–response people cannot feel
        case .continuity: return 0.15   // real, but wake is the weakest channel
        case .autonomic:  return 0.20   // ECG-grade, and ours to own
        case .breathing:  return 0.15   // chest-strap exclusive, ordinal only
        }
    }

    /// Band wording for a night. The exercise vocabulary ("act on it", "keep
    /// doing this") reads as instructions about a workout you chose; nobody
    /// chooses how a night went, and being told to act on your continuity at
    /// breakfast is neither actionable nor kind.
    static func verdict(for value: Int) -> String {
        switch IndexBand.of(value) {
        case .act:     return "below your usual"
        case .improve: return "about usual"
        case .keep:    return "a good night for you"
        }
    }

    var name: String {
        switch self {
        case .timing:     return "Timing"
        case .duration:   return "Duration"
        case .continuity: return "Continuity"
        case .autonomic:  return "Autonomic"
        case .breathing:  return "Breathing"
        }
    }
}

// MARK: - Input

/// Everything the score needs, already measured. Optional throughout: a
/// section with no input is **absent**, never zero.
struct SleepScoreInput {
    var regularityIndex: Float?     // 0–100, needs trailing nights
    var asleepSec: Double?
    var needSec: Double             // this wearer's own need, not a population figure
    var wakeBouts: Int?
    var longestUnbrokenSec: Double?
    var hrNadirDip: Float?          // bpm below the settled-onset rate
    var hrNadirFraction: Double?    // where in the night the nadir fell, 0–1
    var meanRMSSD: Float?
    var steadyFraction: Double?     // share of the night breathing read as steady
}

// MARK: - Score

struct SleepScore {
    let sections: [SleepSection: Int]
    let overall: Int?
    /// The arithmetic, spelled out. The exercise research condemned opaque
    /// composites — none of fourteen consumer composite scores survived
    /// independent validation — so this one shows its working or it does not
    /// ship.
    let arithmetic: String

    static func compute(_ input: SleepScoreInput) -> SleepScore {
        var sections: [SleepSection: Int] = [:]

        if let sri = input.regularityIndex {
            sections[.timing] = round(ramp(Double(sri), worst: 55, best: 90))
        }
        if let asleep = input.asleepSec {
            // Asymmetric, deliberately. Symmetric scoring punished ten hours
            // exactly as hard as four, and the evidence does not support that:
            // short sleep is causally harmful and dose-dependent, while the
            // long-sleep hazard is not supported by Mendelian randomisation,
            // largely disappears under accelerometry, and reads as a marker of
            // illness rather than a cause. The research says it plainly — do
            // not tell users that sleeping long is harmful.
            //
            // So the score climbs to the need and then holds. Sleeping more
            // than you need is not a failure to report.
            let shortfall = max(0, input.needSec - asleep)
            sections[.duration] = round(ramp(-shortfall, worst: -(150 * 60), best: 0))
        }
        if let longest = input.longestUnbrokenSec, let bouts = input.wakeBouts {
            let stretch = ramp(longest, worst: 45 * 60, best: 180 * 60)
            let broken = ramp(Double(-bouts), worst: -12, best: -2)
            sections[.continuity] = round(0.55 * stretch + 0.45 * broken)
        }
        if let dip = input.hrNadirDip {
            // Depth, then placement, then the night's own vagal level. A nadir
            // that arrives near the middle is the settled pattern; one that
            // arrives near morning is the signature evening load leaves.
            var parts: [(Double, Double)] = [(0.45, ramp(Double(dip), worst: 6, best: 18))]
            if let at = input.hrNadirFraction {
                parts.append((0.25, ramp(-abs(at - 0.45), worst: -0.35, best: 0)))
            }
            if let rmssd = input.meanRMSSD {
                parts.append((0.30, ramp(Double(rmssd), worst: 22, best: 62)))
            }
            let totalWeight = parts.reduce(0) { $0 + $1.0 }
            sections[.autonomic] = round(parts.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight)
        }
        if let steady = input.steadyFraction {
            // Anchored on measurement, not on a guess. A settled night on this
            // hardware runs about 76% steady, so the original 0.70–0.98 span
            // scored an ordinary night at zero — the section read as a verdict
            // on the wearer's breathing when it was really a verdict on the
            // anchors.
            sections[.breathing] = round(ramp(steady, worst: 0.45, best: 0.90))
        }

        let present = SleepSection.allCases.filter { sections[$0] != nil }
        let overall: Int?
        if present.count >= SleepThresholds.minSectionsForOverall {
            let weight = present.reduce(0.0) { $0 + $1.weight }
            let sum = present.reduce(0.0) { $0 + $1.weight * Double(sections[$1] ?? 0) }
            overall = Int((sum / weight).rounded())
        } else {
            overall = nil
        }

        // Renormalised weights, so the printed sum actually reaches the
        // headline. Showing the raw weights of a partial set was worse than
        // showing nothing: "46 = 25%·0 + 15%·96 + 20%·67" adds up to 28, and a
        // reader who checks it finds the arithmetic wrong rather than finding
        // out that two sections were missing.
        let liveWeight = present.reduce(0.0) { $0 + $1.weight }
        let line = present
            .map { section -> String in
                let share = liveWeight > 0 ? section.weight / liveWeight : 0
                return "\(Int((share * 100).rounded()))%·\(sections[section] ?? 0) \(section.name.lowercased())"
            }
            .joined(separator: " + ")
        let missing = SleepSection.allCases.filter { sections[$0] == nil }
        let note = missing.isEmpty
            ? ""
            : "  (\(missing.map { $0.name.lowercased() }.joined(separator: " and ")) not measured — "
              + "the rest are reweighted to fill it)"

        return SleepScore(sections: sections,
                          overall: overall,
                          arithmetic: (overall.map { "\($0) = \(line)" } ?? line) + note)
    }

    // MARK: Helpers

    /// Linear between two anchors, clamped. Anchored rather than percentile-
    /// ranked so a first night still scores — the app's own rule that every
    /// section carries a number from day one.
    private static func ramp(_ v: Double, worst: Double, best: Double) -> Double {
        guard best != worst else { return 0 }
        return min(1, max(0, (v - worst) / (best - worst))) * 100
    }

    private static func round(_ v: Double) -> Int { Int(v.rounded()) }
}
