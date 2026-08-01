import Foundation

/// The fitted relationship between vagal tone and cardiovascular work.
struct VSIFit {

    /// Change in lnDC per 10 percentage points of HR reserve.
    ///
    /// Negative: vagal tone falls as intensity rises, which is what should
    /// happen. A steeper (more negative) slope means more vagal shutdown was
    /// spent to reach the same heart rate.
    let slopePer10: Double

    /// How many samples entered the fit, after exclusions. Surfaced so a slope
    /// drawn from eight points is not silently presented like one drawn from
    /// four hundred.
    let sampleCount: Int
}

/// Vagal Suppression Index — how deeply the vagus had to be switched off *for
/// this load*, normalised by internal (heart-rate) work.
///
/// Fitted as a slope across the whole session rather than a single
/// trough-versus-peak ratio, for two reasons. A ratio throws away everything
/// between its two points, so an even session and a spiky one can produce the
/// same number. And it breaks at high intensity: DC floors near zero while
/// %HRR keeps climbing, so the ratio starts measuring the floor.
enum ExerciseSuppression {

    /// A regression needs at least this many surviving points to mean anything.
    static let minimumSamples = 4

    /// Below this spread in %HRR the slope is numerically meaningless — the
    /// line is being fitted through what is effectively one x-value.
    static let minimumHRRSpan: Double = 5

    /// Slope of lnDC against %HRR, in lnDC per 10 %HRR.
    ///
    /// Severe-domain samples are excluded: DC has floored there, so the
    /// numerator physically cannot fall further while the denominator keeps
    /// growing. Including them measures the ceiling of the measurement, not the
    /// person. A `nil` α1 is missing data rather than evidence of the severe
    /// domain, so those samples are kept.
    ///
    /// Returns `nil` — rather than a number — when there is nothing honest to
    /// report: too few points, no spread in intensity, or a session spent
    /// entirely above the severe threshold.
    static func vsi(samples: [(hrrPct: Double, dc: Double, dfa1: Double?)]) -> VSIFit? {
        let usable = samples.filter { s in
            guard s.dc > 0 else { return false }   // ln(0) and ln(<0) poison the fit
            if let a = s.dfa1, ExerciseIntensity.domain(dfa1: a) == .severe { return false }
            return true
        }
        guard usable.count >= minimumSamples else { return nil }

        let xs = usable.map(\.hrrPct)
        guard let lo = xs.min(), let hi = xs.max(), hi - lo >= minimumHRRSpan else { return nil }

        let ys = usable.map { log($0.dc) }
        let n  = Double(usable.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n

        var num = 0.0
        var den = 0.0
        for i in 0..<usable.count {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        guard den > 0 else { return nil }

        return VSIFit(slopePer10: (num / den) * 10, sampleCount: usable.count)
    }

    /// Fraction of pre-session vagal tone withdrawn at the trough, 0…1.
    ///
    /// Descriptive only. Depth is the size of the stimulus, not its quality —
    /// a deep session is the point of training, not a fault in it.
    static func depth(dcTrough: Double, dcPre: Double) -> Double? {
        guard dcPre > 0 else { return nil }
        return min(max(1 - dcTrough / dcPre, 0), 1)
    }
}
