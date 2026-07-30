import Foundation

/// Overall practice impact and the one factual trend line the LLM can't
/// produce. Everything here is derived from each metric's benefit-signed
/// change (during vs before). Pure and unit-tested; views consume it.
enum ActivityImpact {

    /// Short caption for a session's mean benefit-signed delta.
    ///
    /// Describes DIRECTION, not quality. A hard run posts a large negative
    /// delta by design — heart rate up, variability down — and must read as
    /// effort rather than as a poor session.
    static func caption(for delta: Double) -> String {
        switch delta {
        case 12...:        return "deeply restorative"
        case 6..<12:       return "restorative"
        case 2..<6:        return "settling"
        case -2...2:       return "steady"
        case -10 ..< -2:   return "activating"
        default:           return "strongly activating"
        }
    }

    /// How many metrics beat the 2-month baseline. Kept as a deterministic
    /// line because the insight model is never sent that comparison.
    /// Nil when no metric has a baseline to compare against.
    static func trendLine(_ moves: [MetricMovement]) -> String? {
        let compared = moves.filter { $0.vs2mo != nil }.count
        guard compared > 0 else { return nil }
        let beat = moves.filter { ($0.vs2mo ?? 0) > 0 }.count
        return "You beat your 2-month average on \(beat) of \(compared) metrics."
    }
}

/// One metric's session movement.
struct MetricMovement {
    let name:   String   // consumer label, e.g. "Conscious Breathing"
    let uplift: Double?  // benefit-signed % during vs before
    let vs2mo:  Double?  // benefit-signed % during vs 2-month baseline
}
