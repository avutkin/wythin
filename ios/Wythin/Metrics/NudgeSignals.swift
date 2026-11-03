import Foundation

/// The numeric evidence every nudge rule reads, derived once per evaluation.
///
/// Two windows, sized by what the metrics can actually resolve:
///
/// - **slow, 30 min** — RMSSD, DC, PIP and DFA α1 are computed over the whole RR
///   buffer (1200 beats ≈ 20 min), so consecutive ticks share almost all their
///   input. Five buckets across 30 minutes puts the first and last bucket
///   centres 24 min apart, which is the shortest span that makes them
///   genuinely different samples rather than the same data twice.
/// - **fast, 10 min** — only HR (~5 s) and RSA (last 90 RR, ~45 s) move quickly
///   enough to mean anything at this scale.
struct NudgeSignals {

    static let slowWindowMinutes = 30
    static let fastWindowMinutes = 10

    /// Anchor-grade gates, reused so a "you are in a great state" claim can
    /// never be derived from a noisy read.
    static let minSignalQuality: Float = 0.9
    static let minECGTier = 1

    let slow: [String: MetricTrend]
    let fast: [String: MetricTrend]

    /// Derived series, deliberately absent from `LiveStateTrendCompute.keyPaths`
    /// — that list is the server payload contract.
    let slowBalance: MetricTrend?
    let slowMotion:  MetricTrend?
    let fastMotion:  MetricTrend?

    /// Change across the slow window in this person's own SD units.
    ///
    /// Not a live z-score. The baseline is built from rested morning anchors
    /// under strict gates, so live daytime values sit systematically worse by
    /// construction and an absolute live z would be biased. Scoring the
    /// *change* cancels that offset.
    let dzLnRMSSD: Float?
    let dzDC:      Float?

    /// Every point in the slow window cleared the signal-quality and ECG gates.
    let slowSignalClean: Bool

    /// Observed tick spacing, so callers can reason about resolution.
    let cadenceSeconds: Double

    // MARK: - Derivation

    static func derive(from buffer: NudgeSampleBuffer,
                       baseline: AnchorBaseline?,
                       now: Date = .now) -> NudgeSignals? {

        guard let cadence = buffer.medianCadenceSeconds, cadence > 0 else { return nil }

        // A hole in the window breaks the run: sustain counters reset and the
        // window must refill before anything may fire.
        let slowSeconds = Double(slowWindowMinutes) * 60
        guard !buffer.hasGap(inLast: slowSeconds, now: now) else { return nil }

        let points   = buffer.points
        let slowMin  = NudgeSampleBuffer.requiredPoints(windowMinutes: slowWindowMinutes,
                                                        cadenceSeconds: cadence)
        let fastMin  = NudgeSampleBuffer.requiredPoints(windowMinutes: fastWindowMinutes,
                                                        cadenceSeconds: cadence)

        guard let slow = LiveStateTrendCompute.summarize(points,
                                                         windowMinutes: slowWindowMinutes,
                                                         minimumPoints: slowMin,
                                                         now: now) else { return nil }

        let fast = LiveStateTrendCompute.summarize(points,
                                                   windowMinutes: fastWindowMinutes,
                                                   minimumPoints: fastMin,
                                                   now: now) ?? [:]

        func slowSeries(_ value: @escaping (MetricsHistoryPoint) -> Float?) -> MetricTrend? {
            LiveStateTrendCompute.seriesTrend(points, windowMinutes: slowWindowMinutes,
                                              minimumPoints: slowMin, now: now, value: value)
        }

        let balance = slowSeries(Self.balance)
        let slowMot = slowSeries { $0.motion }
        let fastMot = LiveStateTrendCompute.seriesTrend(points, windowMinutes: fastWindowMinutes,
                                                        minimumPoints: fastMin, now: now) { $0.motion }

        let dzLn = dz(slowSeries { $0.rmssd.map { r in log(max(r, 1e-3)) } },
                      sd: baseline?.lnRMSSD.sdBlended(prior: BaselinePrior.lnRMSSD))
        let dzDc = dz(slowSeries { $0.dc },
                      sd: baseline?.dc?.sdBlended(prior: BaselinePrior.dc))

        let cutoff = now.addingTimeInterval(-slowSeconds)
        let inWindow = points.filter { $0.timestamp >= cutoff }
        let clean = !inWindow.isEmpty && inWindow.allSatisfy {
            ($0.signalQuality ?? 0) >= minSignalQuality && ($0.ecgQualityTier ?? 0) >= minECGTier
        }

        return NudgeSignals(slow: slow, fast: fast,
                            slowBalance: balance, slowMotion: slowMot, fastMotion: fastMot,
                            dzLnRMSSD: dzLn, dzDC: dzDc,
                            slowSignalClean: clean, cadenceSeconds: cadence)
    }

    // MARK: - Derived series

    /// The autonomic balance dial exactly as the chart draws it
    /// (`MetricsChartsView` passes `baselineRmssd: nil`), which reduces to
    /// `100 × 40/(RMSSD + 40)`. Its reference lines and the Calm Power
    /// reference lines agree: dial 50 is RMSSD 40, dial 65 is RMSSD 21.5.
    static func balance(_ pt: MetricsHistoryPoint) -> Float? {
        AutonomicCompute.balance(rmssd: pt.rmssd, lf: pt.lfPower, hf: pt.hfPower,
                                 breathBPM: pt.breathBPM, meanBPM: pt.meanBPM,
                                 baselineRmssd: nil)
            .map { $0.sns * 100 }
    }

    /// Bucket endpoints rather than raw endpoints: a single stray tick at either
    /// edge must not decide whether a nudge fires.
    private static func dz(_ trend: MetricTrend?, sd: Float?) -> Float? {
        guard let buckets = trend?.buckets, buckets.count >= 2,
              let sd, sd > 1e-6, let first = buckets.first, let last = buckets.last
        else { return nil }
        return (last - first) / sd
    }
}
