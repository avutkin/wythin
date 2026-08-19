import Foundation

/// Breathing steadiness, from the breath rate the app already measures.
///
/// The first pass reported this section as "not measured" on the grounds that
/// steadiness needs a respiratory-effort waveform from the sternum
/// accelerometer. That was wrong twice over: breath rate is present on 97% of
/// ticks in a real night, and its *variability* is the single best wake/sleep
/// discriminator in that recording — better than heart rate, which stays in
/// the low sixties for three quarters of an hour after a person has stopped
/// being awake.
///
/// Measured across one night: awake, breath rate swings between 6.7 and 20.1
/// from one five-minute bucket to the next. Asleep, it holds 17.1–17.6. That
/// is not a subtle difference, and it was sitting in the data unused.
///
/// What this is NOT: an apnea index, an event rate, or anything per hour. It
/// is the share of the night whose breathing held close to its own rhythm —
/// ordinal, self-referential, and reported that way.
enum SleepBreathing {

    /// Rolling window over which the spread is measured. Long enough that one
    /// noisy estimate cannot mark the whole minute unsteady, short enough to
    /// resolve a settling period rather than averaging across it.
    static let windowSec: Double = 5 * 60

    /// Breath-rate spread (breaths/min) at or below which a tick counts as
    /// steady. Set from measurement: a settled night holds well under half a
    /// breath, and the awake stretches run several times that.
    static let steadySpread: Float = 1.6

    /// Per-tick rolling spread of breath rate, aligned with `points`.
    static func spread(_ points: [MetricsHistoryPoint]) -> [Float?] {
        guard !points.isEmpty else { return [] }
        return points.indices.map { i in
            let centre = points[i].timestamp
            let half = windowSec / 2
            let window = points.lazy
                .filter { abs($0.timestamp.timeIntervalSince(centre)) <= half }
                .compactMap(\.breathBPM)
            let values = Array(window)
            guard values.count >= 3 else { return nil }
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            return sqrt(variance)
        }
    }

    /// Share of the night whose breathing held steady, 0–1. Nil when breath
    /// rate was never recorded — absent rather than zero.
    static func steadyFraction(_ points: [MetricsHistoryPoint]) -> Double? {
        let spreads = spread(points).compactMap { $0 }
        guard !spreads.isEmpty else { return nil }
        let steady = spreads.filter { $0 <= steadySpread }.count
        return Double(steady) / Double(spreads.count)
    }

    /// True where breathing is unsettled enough to suggest the person is not
    /// asleep. Used as a wake cue alongside motion and heart rate.
    static func unsettled(_ points: [MetricsHistoryPoint]) -> [Bool] {
        let spreads = spread(points)
        let observed = spreads.compactMap { $0 }.sorted()
        guard !observed.isEmpty else { return points.map { _ in false } }
        let median = observed[observed.count / 2]
        // Relative to this recording, like every other gate: a person's own
        // breathing regularity is the reference, not a population figure.
        let threshold = max(steadySpread, median * SleepThresholds.unsettledBreathMultiple)
        return spreads.map { ($0 ?? 0) > threshold }
    }
}
