import Foundation

/// How long the vagal brake took to come halfway back.
///
/// This replaces a percentage, which was the wrong shape for the question. A
/// level at a fixed moment says nothing about direction: a session whose vagal
/// tone was still *falling* ten minutes later reported "37 % of resting" —
/// technically the level, but read as though 37 % had been recovered when
/// nothing had. A duration cannot be misread that way, and when recovery does
/// not happen it says so instead of quoting a number.
enum RecoveryTiming {

    /// The bar: halfway back **from where it bottomed out to where it started**.
    ///
    /// Not half of the resting level, which was the first attempt and is wrong:
    /// for a session whose vagal tone never fell below half of resting, that bar
    /// sits under the trough and is already met the moment you stop — reporting
    /// "halfway back in 0 minutes" for a session that had barely dipped.
    ///
    /// Measuring against the fall makes it a recovery fraction rather than an
    /// absolute level, so a light session and a brutal one are asked the same
    /// question: how long to climb half of your own hole.
    ///
    /// Halfway rather than full return because a full return often falls outside
    /// the recording, which would make the metric absent precisely on the
    /// hardest sessions.
    static let targetFraction: Double = 0.5

    /// The level being climbed to, given where it started and where it fell to.
    static func targetLevel(dcPre: Double, dcTrough: Double) -> Double {
        dcTrough + (dcPre - dcTrough) * targetFraction
    }

    /// Once reached, it must hold above this share of the target — a single
    /// noisy sample crossing the line is not recovery.
    static let holdFraction: Double = 0.9

    /// How long the level must hold after crossing before the crossing counts.
    ///
    /// **Bounded, and that is the fix.** The hold used to be tested against
    /// every remaining sample, and `computeRecoveryTiming` fetches four hours
    /// after the session — so the rule was "recover, then never dip again for
    /// four hours". Post-exercise vagal tone is not monotonic; over hours it
    /// certainly dips. One recorded session came back within four minutes and
    /// scored zero because of a single sag twenty minutes later, while the
    /// chart beside the number said it had recovered. The longer the strap
    /// stayed on, the more certainly the metric reported failure.
    ///
    /// Five minutes is long enough to reject the noisy touch the hold exists to
    /// catch, and short enough that a dip an hour later cannot retroactively
    /// un-recover you. It sits above the ≥2 min post-exercise window the
    /// reactivation literature treats as reliable (Stanley, Peake & Buchheit,
    /// Sports Medicine 2013).

    static let holdMinutes: Double = 5

    /// A window shorter than this cannot support "it never got there".
    static let minimumObservationMinutes: Double = 8

    enum Outcome: Equatable {
        /// Minutes after the session ended.
        case reached(minutes: Double)
        /// Watched this long and it never came halfway back.
        case notReached(observedMinutes: Double)
        /// Too little recording after the session to say anything.
        case notObserved
    }

    /// - Parameter after: (minutes since the session ended, DC), any order.
    /// - Parameter dcTrough: the lowest vagal tone reached during the session.
    ///   Without it there is no fall to measure the climb against.
    static func halfRecovery(after: [(minutes: Double, dc: Double)],
                             dcPre: Double?,
                             dcTrough: Double?) -> Outcome {
        guard let dcPre, dcPre > 0, let dcTrough else { return .notObserved }
        // A session that never suppressed has no hole to climb out of.
        guard dcPre > dcTrough else { return .notObserved }
        let series = after.filter { $0.minutes >= 0 }.sorted { $0.minutes < $1.minutes }
        guard let observed = series.last?.minutes, !series.isEmpty else { return .notObserved }

        let target = targetLevel(dcPre: dcPre, dcTrough: dcTrough)
        // Every crossing is tried, not just the first. A brief touch that falls
        // away is not recovery, but it is also not proof that recovery never
        // came — the old code took `firstIndex` and gave up on it, so a session
        // that flickered at three minutes and genuinely returned at twenty
        // reported never.
        for idx in series.indices where series[idx].dc >= target {
            let deadline = series[idx].minutes + holdMinutes
            let window = series[idx...].prefix { $0.minutes <= deadline }
            // A recording that stops inside the window is judged on what it
            // has. Demanding the full five minutes would report failure for a
            // session that recovered and then had the strap taken off.
            if window.allSatisfy({ $0.dc >= target * holdFraction }) {
                return .reached(minutes: series[idx].minutes)
            }
        }
        return observed >= minimumObservationMinutes
            ? .notReached(observedMinutes: observed)
            : .notObserved
    }

    /// 0–100 for the overall score, from the time taken.
    ///
    /// Anchored rather than percentile-ranked so it means the same thing on day
    /// one as after a year: three minutes or less is as good as this gets,
    /// twenty-five minutes is the bottom. Never reaching halfway inside a
    /// window long enough to judge scores zero — that is information, not a
    /// missing value.
    static let fastMinutes: Double = 3
    static let slowMinutes: Double = 25

    static func score(_ outcome: Outcome) -> Int? {
        switch outcome {
        case let .reached(minutes):
            let t = (minutes - fastMinutes) / (slowMinutes - fastMinutes)
            return Int((100 * (1 - min(max(t, 0), 1))).rounded())
        case .notReached:
            return 0
        case .notObserved:
            return nil
        }
    }

    /// The sentence shown under the chart.
    static func summary(_ outcome: Outcome) -> String {
        switch outcome {
        case let .reached(minutes) where minutes < 1:
            return "Your vagal brake was already halfway back when you stopped."
        case let .reached(minutes):
            return "Halfway back to your resting level \(Int(minutes.rounded())) minutes after you stopped."
        case let .notReached(observed):
            return "Still less than halfway back \(Int(observed.rounded())) minutes after you stopped — this one is taking a while to clear."
        case .notObserved:
            return "Not enough recording after this session to see recovery."
        }
    }
}
