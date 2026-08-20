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

    /// Breath rate is first reduced to a median every `binSec`, and the spread
    /// is then measured across `windowSec` of those bins.
    ///
    /// The timescale matters more than the threshold, and getting it wrong
    /// inverted the result. Measured tick-to-tick over five minutes, awake and
    /// asleep are indistinguishable — awake evening p50 1.02 against asleep
    /// 1.18, with asleep marginally HIGHER. Measured as the swing of
    /// five-minute medians across twenty minutes, they separate cleanly: awake
    /// p50 2.14 against asleep 0.59. Breathing during sleep is noisy from
    /// breath to breath and steady in its rhythm; awake it is the other way
    /// round.
    static let binSec: Double = 5 * 60
    static let windowSec: Double = 20 * 60

    /// Spread of those binned medians (breaths/min) at or below which
    /// breathing counts as steady. Measured against a settled night: 1.5
    /// admits 76% of asleep time while still sitting clear of the awake median
    /// of 2.14. Tighter values eat into ordinary sleep — 1.25 admitted only
    /// 68%, and 1.0 just 62%.
    static let steadySpread: Float = 1.5

    /// Per-tick spread of the binned breath rate, aligned with `points`.
    static func spread(_ points: [MetricsHistoryPoint]) -> [Float?] {
        guard !points.isEmpty, let first = points.first else { return [] }

        // Bin to medians first. Without this the measure reads breath-to-breath
        // jitter, which does not distinguish sleep from waking at all.
        var bins: [Int: [Float]] = [:]
        for p in points {
            guard let b = p.breathBPM else { continue }
            let bin = Int(p.timestamp.timeIntervalSince(first.timestamp) / binSec)
            bins[bin, default: []].append(b)
        }
        let medians: [Int: Float] = bins.compactMapValues { values in
            guard values.count >= 3 else { return nil }
            let s = values.sorted()
            return s[s.count / 2]
        }
        guard !medians.isEmpty else { return points.map { _ in nil } }

        let reach = Int((windowSec / binSec) / 2)
        return points.map { p in
            let bin = Int(p.timestamp.timeIntervalSince(first.timestamp) / binSec)
            let window = ((bin - reach)...(bin + reach)).compactMap { medians[$0] }
            guard window.count >= 3 else { return nil }
            let mean = window.reduce(0, +) / Float(window.count)
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(window.count)
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
