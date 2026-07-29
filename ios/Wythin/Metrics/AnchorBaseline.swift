import Foundation

/// Typical within-person day-to-day spread, used as a prior so a baseline
/// built from two or three days can still be scored.
///
/// An SD estimated from three days carries roughly 50% relative error, and
/// since the score is 50 + 25·z, a naive early z swings the number 40+ points
/// on estimation noise alone. Blending toward these constants is what makes an
/// early score honest rather than merely present.
///
/// These are literature-informed figures, not this user's. They dominate at
/// n = 1 and are nearly irrelevant by n = 20. Checked 2026-07-28 against 30
/// days of local morning history: rolling-7 SD of daily median lnRMSSD had a
/// median of 0.275 — but that sample is ungated (no stillness, signal-quality
/// or ECG-tier filtering available in that store), so it is an upper bound and
/// 0.20 sits plausibly below it. `restingHR` could not be checked at all: the
/// same rows average 78 bpm, which is activity, not rest. Treat it as
/// unverified and recalibrate both once ~30 real anchors exist.
enum BaselinePrior {
    static let lnRMSSD:   Float = 0.20   // ln units (≈20% RMSSD CV)
    static let restingHR: Float = 3.0    // bpm
    static let dc:        Float = 1.2    // ms
    static let pip:       Float = 4.0    // %

    /// Virtual days of prior evidence. At n = strength the blend is 50/50.
    static let strength: Float = 4
}

/// Mean/SD/n for one metric across the baseline window.
struct BaselineStat: Equatable {
    let mean: Float
    let sd:   Float
    let n:    Int

    /// z of `value`, or nil when the SD is degenerate.
    ///
    /// Raw — no prior. Kept for callers that want the plain statistic; scored
    /// components use `z(_:prior:)` instead.
    func z(_ value: Float) -> Float? {
        guard sd > 1e-6 else { return nil }
        return (value - mean) / sd
    }

    /// z against a prior-blended, prediction-widened SD.
    ///
    /// Two separate problems, one term each:
    ///
    /// - `sdBlend` fixes the unstable SD. A spuriously *small* sample SD is
    ///   what produces a monster z, so it is pulled toward `prior` with weight
    ///   `BaselinePrior.strength`. At n = 1 the `(n − 1)` term zeroes and this
    ///   is exactly the prior — the formula degrades with no special case.
    /// - `sqrt(1 + 1/n)` fixes the unstable *mean*. At n = 2 the standard error
    ///   of the mean is 0.71·sd, so today can read as extreme purely because
    ///   the two reference days happened to sit low. This is the standard
    ///   prediction-interval widening.
    ///
    /// Both fade on their own: the multiplier on a typical SD is 1.41x at
    /// n = 1, 1.22x at n = 2, 1.07x at n = 7, 1.03x at n = 20. There is no
    /// discontinuity when the baseline is declared firm.
    func z(_ value: Float, prior: Float) -> Float? {
        guard let sdPred = sdBlended(prior: prior) else { return nil }
        return (value - mean) / sdPred
    }

    /// The denominator `z(_:prior:)` divides by, exposed on its own.
    ///
    /// Scores that compare a *change* against this person's spread — rather than
    /// a value against their mean — need the SD without the centring. Sharing
    /// one implementation keeps the two from drifting apart.
    func sdBlended(prior: Float) -> Float? {
        guard n >= 1, prior > 1e-6 else { return nil }
        let nu = BaselinePrior.strength
        let personal = Float(n - 1) * sd * sd
        let blendVar = (nu * prior * prior + personal) / (nu + Float(n - 1))
        let sdPred = blendVar.squareRoot() * (1 + 1 / Float(n)).squareRoot()
        return sdPred > 1e-6 ? sdPred : nil
    }
}

/// The user's own norm, built from stored anchors.
///
/// Nothing here is population-referenced — every comparison is against the
/// same person. Single-day-vs-single-day comparison is noise; the validated
/// approach (Plews et al.) is a rolling personal baseline with a
/// smallest-worthwhile-change band, which is what the z-scores here feed.
struct AnchorBaseline {
    let lnRMSSD:     BaselineStat
    let restingHR:   BaselineStat
    let dc:          BaselineStat?
    let pip:         BaselineStat?
    let dfa1Median:  Float?
    /// CV of the last 7 lnRMSSD anchors — the stability axis. Rising
    /// day-to-day variability warns earlier than the level does.
    let cv7:         Float?
    /// Distribution of historical rolling CV7s, so `cv7` can be z-scored.
    let cv7Stat:     BaselineStat?
    let medianHour:  Double
    let anchorCount: Int
    let hourMatched: Bool
    /// Fewer anchors than `firmAnchors` — the score is real but early, and the
    /// prior is still carrying much of the weight.
    let provisional: Bool

    /// The point at which the baseline is the user's own rather than mostly
    /// prior. A *label* threshold, not a compute gate — scoring starts at one
    /// prior anchor.
    static let firmAnchors = 7
    static let windowDays  = 60
    /// Anchors within this many hours of today's count as like-for-like.
    /// HRV has strong circadian variation — a 07:00 and a 15:00 read are not
    /// comparable, so the baseline prefers same-hour history.
    static let hourTolerance: Double = 2

    static func build(history: [AnchorReading],
                      todayHour: Double,
                      now: Date = .now) -> AnchorBaseline? {

        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? .distantPast
        let inWindow = history
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }       // newest first
        guard !inWindow.isEmpty else { return nil }

        let nearHour = inWindow.filter { abs($0.hour - todayHour) <= hourTolerance }
        // Hour matching is a luxury. Below `firmAnchors` near-hour samples the
        // baseline uses everything it has rather than starving itself.
        let hourMatched = nearHour.count >= firmAnchors
        let sample = hourMatched ? nearHour : inWindow

        guard let lnStat = stat(sample.map { $0.lnRMSSD }),
              let hrStat = stat(sample.map { $0.restingHR }) else { return nil }

        let lnSeriesNewestFirst = sample.map { $0.lnRMSSD }
        let cv7 = coefficientOfVariation(Array(lnSeriesNewestFirst.prefix(7)))

        // The same rolling statistic across the window, so today's CV7 can be
        // z-scored against the person's own usual spread rather than a guess.
        var rollingCVs: [Float] = []
        if lnSeriesNewestFirst.count >= 8 {
            for startIdx in 0...(lnSeriesNewestFirst.count - 7) {
                if let cv = coefficientOfVariation(Array(lnSeriesNewestFirst[startIdx..<(startIdx + 7)])) {
                    rollingCVs.append(cv)
                }
            }
        }

        return AnchorBaseline(
            lnRMSSD:     lnStat,
            restingHR:   hrStat,
            dc:          stat(sample.compactMap { $0.dc }),
            pip:         stat(sample.compactMap { $0.pip }),
            dfa1Median:  AnchorDetector.median(sample.compactMap { $0.dfa1 }),
            cv7:         cv7,
            cv7Stat:     rollingCVs.count >= 2 ? stat(rollingCVs) : nil,
            medianHour:  Double(AnchorDetector.median(sample.map { Float($0.hour) }) ?? Float(todayHour)),
            anchorCount: inWindow.count,
            hourMatched: hourMatched,
            provisional: inWindow.count < firmAnchors)
    }

    // MARK: Stats

    /// A single value yields sd = 0, which is correct rather than degenerate:
    /// `z(_:prior:)` reads that as "no personal evidence yet" and falls back to
    /// the prior alone.
    private static func stat(_ values: [Float]) -> BaselineStat? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Float(values.count)
        guard values.count >= 2 else { return BaselineStat(mean: mean, sd: 0, n: 1) }
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count - 1)
        return BaselineStat(mean: mean, sd: variance.squareRoot(), n: values.count)
    }

    private static func coefficientOfVariation(_ values: [Float]) -> Float? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Float(values.count)
        guard abs(mean) > 1e-6 else { return nil }
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count - 1)
        return variance.squareRoot() / abs(mean)
    }
}
