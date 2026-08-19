import Foundation

/// Sleep Regularity Index — the percentage of the time the wearer is in the
/// same state (asleep or awake) at the same clock time on two consecutive days.
///
/// This is the highest-value metric in the whole sleep model and the cheapest
/// to compute: it needs only onset and wake times, no staging and no ECG.
///
/// It earns that place on the evidence. In 60,977 UK Biobank participants the
/// most-regular quintile carried an all-cause mortality hazard of 0.70 against
/// the least regular — and head-to-head, **adding sleep duration to a model
/// already containing SRI added nothing** (likelihood-ratio χ²(4)=5.94,
/// p=0.20). Regularity beat duration, which is the opposite of where every
/// consumer sleep product puts its emphasis.
///
/// Scale follows Phillips et al.: 100 is perfect regularity, 0 is no better
/// than chance, and negative values (systematically opposite states 24 h apart)
/// are possible in principle and clamped away here as meaningless in practice.
enum SleepRegularity {

    /// Resolution of the comparison. One minute is finer than the measurement
    /// deserves but costs nothing and avoids an arbitrary epoch boundary.
    private static let stepSec: Double = 60

    static func index(of windows: [SleepWindow]) -> Float? {
        guard windows.count >= SleepThresholds.minNightsForSRI else { return nil }

        let sorted = windows.sorted { $0.startedAt < $1.startedAt }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        // Walk the whole span a minute at a time, comparing each moment with
        // the same clock time one day earlier.
        let day: Double = 24 * 3600
        let start = first.startedAt
        let end = last.endedAt
        guard end > start + day else { return nil }

        var agreements = 0
        var comparisons = 0
        var t = start + day
        while t <= end {
            let now = isAsleep(t, in: sorted)
            let yesterday = isAsleep(t - day, in: sorted)
            if now == yesterday { agreements += 1 }
            comparisons += 1
            t += stepSec
        }
        guard comparisons > 0 else { return nil }

        let concordance = Double(agreements) / Double(comparisons)
        return Float(max(0, 200 * concordance - 100))
    }

    private static func isAsleep(_ t: Date, in windows: [SleepWindow]) -> Bool {
        windows.contains { $0.startedAt <= t && t < $0.endedAt }
    }
}
