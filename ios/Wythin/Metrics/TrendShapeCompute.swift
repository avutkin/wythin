import Foundation

/// The arc of a metric across the live window, as a label the model can read
/// directly. Small models misread a bare sequence of similar floats and
/// invent movement that isn't there — the label removes that guesswork.
enum TrendShape: String, Equatable {
    case steadyRise      = "steady-rise"
    case steadyFall      = "steady-fall"
    case plateau         = "plateau"
    case spikeAndRecover = "spike-and-recover"
    case dipAndRecover   = "dip-and-recover"
    case oscillating     = "oscillating"
}

enum TrendShapeCompute {

    /// Relative range below which the whole window counts as flat.
    static let plateauRelRange: Float = 0.03
    /// Relative step below which a bucket-to-bucket move is noise.
    static let significantStep: Float = 0.01

    static func classify(_ buckets: [Float]) -> TrendShape {
        guard buckets.count >= 3 else { return .plateau }

        let mean  = buckets.reduce(0, +) / Float(buckets.count)
        let scale = max(abs(mean), 1e-6)
        guard let maxV = buckets.max(), let minV = buckets.min() else { return .plateau }
        if (maxV - minV) / scale < plateauRelRange { return .plateau }

        // Significant steps only; noise-level moves are ignored.
        var signs: [Int] = []
        for i in 1..<buckets.count {
            let d = buckets[i] - buckets[i - 1]
            if abs(d) / scale > significantStep { signs.append(d > 0 ? 1 : -1) }
        }
        guard !signs.isEmpty else { return .plateau }

        var reversals = 0
        if signs.count >= 2 {
            for i in 1..<signs.count where signs[i] != signs[i - 1] { reversals += 1 }
        }

        let net = buckets[buckets.count - 1] - buckets[0]

        if reversals == 0 { return net > 0 ? .steadyRise : .steadyFall }

        if reversals == 1 {
            let maxIdx = buckets.firstIndex(of: maxV) ?? 0
            let minIdx = buckets.firstIndex(of: minV) ?? 0
            let interior = 1...(buckets.count - 2)
            let highestEnd = max(buckets[0], buckets[buckets.count - 1])
            let lowestEnd  = min(buckets[0], buckets[buckets.count - 1])
            if interior.contains(maxIdx), (maxV - highestEnd) / scale > plateauRelRange {
                return .spikeAndRecover
            }
            if interior.contains(minIdx), (lowestEnd - minV) / scale > plateauRelRange {
                return .dipAndRecover
            }
            return net > 0 ? .steadyRise : .steadyFall
        }

        return .oscillating
    }

    /// "low" | "moderate" | "high" from the spread of the buckets.
    static func volatility(_ buckets: [Float]) -> String {
        guard buckets.count >= 2 else { return "low" }
        let mean  = buckets.reduce(0, +) / Float(buckets.count)
        let scale = max(abs(mean), 1e-6)
        let variance = buckets.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(buckets.count)
        let rel = variance.squareRoot() / scale
        if rel < 0.02 { return "low" }
        if rel < 0.05 { return "moderate" }
        return "high"
    }
}
