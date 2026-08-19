import Foundation

/// Tracks breathing rate over time instead of re-picking it from scratch
/// every tick.
///
/// A spectral peak is re-chosen every two seconds from independent noise, so
/// the raw estimate can jump 6 → 22 → 9 br/min between adjacent samples —
/// swings no lung can perform. Breathing rate is physiologically continuous:
/// it drifts, it can be changed deliberately over several seconds, but it does
/// not teleport. This is a scalar Kalman filter over that continuity, with an
/// outlier gate so a genuine fast change is still followed rather than
/// suppressed forever.
///
/// Pure value type with no clock of its own — the caller passes elapsed time —
/// so the whole thing is unit-testable.
struct BreathRateTracker {

    /// One estimator's opinion for this tick.
    struct Estimate {
        let bpm: Float
        /// Peak prominence (peak-to-mean). Higher = a cleaner, more dominant
        /// breathing line; drives how much this estimate is trusted.
        let confidence: Float

        init(bpm: Float, confidence: Float) {
            self.bpm = bpm
            self.confidence = confidence
        }
    }

    /// How fast breathing can genuinely drift, in (br/min)² per second.
    ///
    /// At the original 1.0 the predicted uncertainty grew ~2 per tick against
    /// a measurement noise of ~4.5, leaving a Kalman gain near 0.5 — a
    /// two-sample average, which the validation harness showed was *worse*
    /// than the raw per-tick picks it was meant to clean up. At 0.15 the gain
    /// settles near 0.23 (~4–5 ticks of averaging) while a deliberate 8
    /// br/min change still converges inside ten ticks.
    static let processNoise: Float = 0.15
    /// Measurement noise for a peak sitting at the acceptance threshold. Scaled
    /// by confidence: a prominence-9 peak is trusted ~3× more than a
    /// prominence-3 one.
    static let baseMeasurementNoise: Float = 9.0
    /// Gate width in standard deviations. Beyond this, a reading is treated as
    /// an outlier rather than folded in.
    ///
    /// 2.5, not 3: at steady state the gate sits at 2.5·√(p+r) ≈ 6 br/min, and
    /// simulation showed a 7 br/min spike landing exactly on the 3σ boundary
    /// and being folded in — dragging the tracked rate 2 br/min off truth in
    /// one tick. Sustained changes are unaffected; they arrive as a *run* of
    /// agreeing outliers and re-seed the filter through the path below.
    static let gateSigma: Float = 2.5
    /// Consecutive gated readings that agree with each other before the filter
    /// concedes the breathing really did change and re-seeds. Three ticks ≈ 6 s
    /// of consistent evidence.
    static let outliersBeforeReseed = 3

    private(set) var bpm: Float?
    private var variance: Float = 0
    private var outliers: [Float] = []

    /// Folds this tick's estimates into the tracked rate and returns it.
    ///
    /// - Parameters:
    ///   - candidates: every estimator that produced a reading this tick.
    ///     Empty means nothing was measurable — the tracked value is held, not
    ///     cleared, because a momentarily unreadable spectrum is not evidence
    ///     that breathing stopped.
    ///   - dt: seconds since the previous update.
    mutating func update(_ candidates: [Estimate], dt: Float) -> Float? {
        guard let fused = Self.fuse(candidates) else { return bpm }

        guard var x = bpm else {          // first reading seeds the filter
            bpm = fused.bpm
            variance = Self.baseMeasurementNoise
            return bpm
        }

        // Predict: uncertainty grows with elapsed time.
        var p = variance + Self.processNoise * max(dt, 0)
        let r = Self.baseMeasurementNoise * (minPeakToMean / max(fused.confidence, minPeakToMean))

        // Gate: is this reading plausible given where we think we are?
        if abs(fused.bpm - x) > Self.gateSigma * (p + r).squareRoot() {
            outliers.append(fused.bpm)
            // Re-seed only if the outliers agree with each other — a run of
            // scattered spikes is noise, a run of consistent ones is a real
            // change the filter mispredicted.
            if outliers.count >= Self.outliersBeforeReseed {
                let mean = outliers.reduce(0, +) / Float(outliers.count)
                let spread = outliers.map { abs($0 - mean) }.max() ?? 0
                if spread <= Self.gateSigma * r.squareRoot() {
                    bpm = mean
                    variance = r
                }
                outliers.removeAll()
            }
            return bpm
        }
        outliers.removeAll()

        // Correct.
        let k = p / (p + r)
        x += k * (fused.bpm - x)
        p *= (1 - k)
        bpm = x
        variance = p
        return bpm
    }

    /// Mirrors `BreathingCompute.minPeakToMean` / `EDRCompute.minPeakToMean` —
    /// the prominence at which a peak is accepted at all, and therefore the
    /// point where measurement noise is at its worst.
    private var minPeakToMean: Float { 3.0 }

    /// Combines this tick's estimators.
    ///
    /// Agreeing sources are averaged by confidence — two independent channels
    /// pointing at the same rate is stronger evidence than either alone.
    /// Disagreeing sources cannot both be right, so the more prominent peak
    /// wins outright rather than being averaged into a rate nobody measured.
    static func fuse(_ candidates: [Estimate]) -> Estimate? {
        let valid = candidates.filter { $0.bpm.isFinite && $0.confidence > 0 }
        guard let strongest = valid.max(by: { $0.confidence < $1.confidence }) else { return nil }

        let agreeing = valid.filter { abs($0.bpm - strongest.bpm) <= 2.0 }
        guard agreeing.count > 1 else { return strongest }

        let weight = agreeing.reduce(Float(0)) { $0 + $1.confidence }
        let bpm = agreeing.reduce(Float(0)) { $0 + $1.bpm * $1.confidence } / weight
        return Estimate(bpm: bpm, confidence: weight)
    }

    /// Forgets the tracked state — for a strap-off/standby cycle, where the
    /// next reading belongs to a different stretch of time entirely.
    mutating func reset() {
        bpm = nil
        variance = 0
        outliers.removeAll()
    }
}
