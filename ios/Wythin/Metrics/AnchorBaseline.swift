import Foundation

/// Mean/SD/n for one metric across the baseline window.
struct BaselineStat: Equatable {
    let mean: Float
    let sd:   Float
    let n:    Int

    /// z of `value`, or nil when the SD is degenerate.
    func z(_ value: Float) -> Float? {
        guard sd > 1e-6 else { return nil }
        return (value - mean) / sd
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

    /// Below this many anchors there is no SD, so no score.
    static let minimumAnchors = 7
    static let windowDays     = 60
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
        guard inWindow.count >= minimumAnchors else { return nil }

        let nearHour = inWindow.filter { abs($0.hour - todayHour) <= hourTolerance }
        let hourMatched = nearHour.count >= minimumAnchors
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
            hourMatched: hourMatched)
    }

    // MARK: Stats

    private static func stat(_ values: [Float]) -> BaselineStat? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Float(values.count)
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
