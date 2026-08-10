import Foundation

/// How you turned up, scored 0–100 from the window before the session started.
///
/// It is the only reading on the screen you could still have acted on: sleep,
/// overnight recovery and yesterday's load are all already in the body by the
/// time the first rep happens. After the fact it stops being advice and becomes
/// the explanation for why the load landed the way it did.
///
/// Scored against **your own** recent pre-session windows rather than a
/// population norm. A resting heart rate of 54 means nothing without knowing
/// whose it is, and the same is true of every input here.
enum ReadinessScore {

    static let displayName = "Readiness"

    /// Fewer peers than this and a percentile is noise pretending to be a
    /// measurement, so no score is offered at all.
    static let minimumPeers = 5

    /// One input, with the direction that counts as better.
    struct Component {
        let today: Double
        let peers: [Double]
        /// True when a larger number is the better one — vagal tone, not pulse.
        let higherIsBetter: Bool
    }

    /// Where today sits in the span of your own recent values, 0–100.
    ///
    /// The 10th and 90th percentiles bound it rather than min and max: one
    /// unusually bad night should not permanently redefine the bottom of the
    /// scale.
    static func componentScore(_ c: Component) -> Int? {
        guard c.peers.count >= minimumPeers else { return nil }
        let sorted = c.peers.sorted()
        let low  = percentile(sorted, 0.10)
        let high = percentile(sorted, 0.90)
        guard low != high else { return 50 }
        return c.higherIsBetter
            ? SessionIndices.ramp(c.today, best: high, worst: low)
            : SessionIndices.ramp(c.today, best: low,  worst: high)
    }

    /// Linear-interpolated percentile of an already-sorted series.
    ///
    /// Indexing by `Int(p × (n-1))` truncates, so at ten peers the 10th
    /// percentile lands on element 0 — the minimum. That makes the "robust"
    /// bound the single worst day, which is the exact thing the percentile was
    /// chosen to avoid.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let t = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * t
    }

    /// The mean of whichever components resolved.
    ///
    /// Averaged rather than weighted because there is no evidence for a
    /// weighting here, and inventing one would dress a guess as a measurement.
    static func score(_ components: [Component]) -> Int? {
        let present = components.compactMap(componentScore)
        guard !present.isEmpty else { return nil }
        return Int((Double(present.reduce(0, +)) / Double(present.count)).rounded())
    }

    static func index(value: Int?, peerCount: Int) -> ScoredIndex? {
        guard let value else { return nil }
        return ScoredIndex(
            name: displayName,
            value: value,
            verdict: value >= IndexBand.keepAbove ? "good to train on"
                   : value >= IndexBand.actBelow  ? "an ordinary day"
                                                  : "arrived under-recovered",
            detail: "vs your last \(peerCount)")
    }
}
