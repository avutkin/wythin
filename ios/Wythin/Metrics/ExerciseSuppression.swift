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

    /// Vagal tone rose with heart rate — no suppression to measure. True for
    /// yoga and mobility work, where the brake comes on rather than off.
    var vagalRose: Bool = false
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

    /// The same idea in milli-g, for the motion regression Efficiency uses.
    /// Matches the floor that decides motion is a usable work signal at all.
    static var minimumMotionSpan: Double { Double(ExerciseIntensity.minimumMotionSpan) }

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
    /// - Parameter minimumSpan: how much spread in x the fit needs to mean
    ///   anything, **in the units of x**. Defaults to the %HRR figure. Efficiency
    ///   regresses against motion in milli-g, where five points of spread is a
    ///   completely different and far weaker bar than five points of heart-rate
    ///   reserve — reusing one constant across two units silently accepted fits
    ///   that should have been rejected.
    static func vsi(samples: [(hrrPct: Double, dc: Double, dfa1: Double?)],
                    minimumSpan: Double = minimumHRRSpan) -> VSIFit? {
        let usable = samples.filter { s in
            guard s.dc > 0 else { return false }   // ln(0) and ln(<0) poison the fit
            if let a = s.dfa1, ExerciseIntensity.domain(dfa1: a) == .severe { return false }
            return true
        }
        guard usable.count >= minimumSamples else { return nil }

        let xs = usable.map(\.hrrPct)
        guard let lo = xs.min(), let hi = xs.max(), hi - lo >= minimumSpan else { return nil }

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
        let slope = (num / den) * 10

        // A positive slope means vagal tone *rose* as heart rate rose.
        //
        // At real training intensity that is artifact. But in yoga, stretching
        // and mobility work it is exactly what happens: the heart rate lift is
        // small, the breathing is deliberate, and the vagal brake comes on
        // rather than off. Calling that "no fit" was wrong — the fit is fine,
        // the session simply did not suppress anything.
        //
        // So it is returned, flagged, and left unscored: ranking it against
        // sessions that did suppress would compare two different things.
        return VSIFit(slopePer10: slope, sampleCount: usable.count,
                      vagalRose: slope > 0)
    }

    /// The plain-language Vagal Suppression Index: how much vagal brake was
    /// given up per extra beat of heart rate.
    ///
    /// `slopePer10` above is the refined form, fitted across the whole session.
    /// It needs DC at many points, and during resistance work DC frequently
    /// cannot be computed at all — PRSA wants 150 clean intervals and twenty
    /// deceleration anchors, which a set of heavy singles does not provide. So
    /// the axis fell back to a dash on exactly the sessions people most want it
    /// for.
    ///
    /// This form needs only the two window averages the app already stores, so
    /// it is available whenever the session is. It is also the definition in
    /// plain words — ΔDC over ΔHR — and it carries a unit a person can hold:
    /// milliseconds of brake released per beat per minute gained.
    ///
    /// Returns nil when heart rate did not meaningfully rise, since dividing by
    /// a near-zero ΔHR produces a number that is large for no reason.
    static func brakePerBeat(dcPre: Double?, dcDuring: Double?,
                             hrPre: Double?, hrDuring: Double?) -> Double? {
        guard let dcPre, let dcDuring, let hrPre, let hrDuring else { return nil }
        let deltaHR = hrDuring - hrPre
        guard deltaHR >= minimumHRRise else { return nil }
        return (dcPre - dcDuring) / deltaHR
    }

    /// Below this rise in heart rate there was no meaningful activation to
    /// normalise against.
    static let minimumHRRise: Double = 8

    /// Fraction of pre-session vagal tone withdrawn at the trough, 0…1.
    ///
    /// Descriptive only. Depth is the size of the stimulus, not its quality —
    /// a deep session is the point of training, not a fault in it.
    static func depth(dcTrough: Double, dcPre: Double) -> Double? {
        guard dcPre > 0 else { return nil }
        return min(max(1 - dcTrough / dcPre, 0), 1)
    }
}
