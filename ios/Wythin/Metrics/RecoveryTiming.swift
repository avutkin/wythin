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

    /// The bar's arithmetic alone, with no check that there is a fall worth
    /// measuring.
    ///
    /// **Not the function to score with** — `Direction.target(pre:extreme:)` is,
    /// and it applies `minimumDrawdownFraction`. This one exists so a test can
    /// state the arithmetic on its own, and so the two can be shown to differ
    /// on the session that made the floor necessary.
    static func targetLevel(dcPre: Double, dcTrough: Double) -> Double {
        dcTrough + (dcPre - dcTrough) * targetFraction
    }

    /// The smallest excursion that makes "how fast did it come back" a
    /// question at all, as a share of the pre-session level.
    ///
    /// **Without it the bar collapses onto the trace.** The bar being scored
    /// sits halfway across the excursion, so a session whose vagal brake dipped
    /// 1 % puts that bar half a per cent below resting — inside the
    /// sample-to-sample scatter of the measurement itself. The first sample
    /// after the session clears it, `crossing` returns 0.2 minutes, and the
    /// section prints a perfect 100 for a recovery that never had to happen.
    ///
    /// A photographed yoga session did exactly that: the card read "0.2 min to
    /// halfway" and "100 / 100 · recovery" above a chart whose resting line and
    /// halfway line were drawn a hair apart — and whose "during" curve had gone
    /// *up*. The brake settled at 14.5 ms; the trough it was scored against sat
    /// a fraction under resting, which is a reconstruction of that geometry
    /// rather than a value read back off the device.
    ///
    /// A tenth costs nothing on the sessions this analysis is for: real vagal
    /// withdrawal takes the trough to a fraction of resting, not a percent off
    /// it, and every fixture in `RecoveryTimingTests` falls by a quarter or
    /// more. It only removes the reading where there was never anything to
    /// read, which is the honest outcome — reported as "barely moved", never
    /// as a missing recording and never as a hundred.
    static let minimumDrawdownFraction: Double = 0.10

    /// Back inside this share of the resting level counts as home.
    ///
    /// The halfway bar above is what the score is built from, because a full
    /// return often falls outside the recording. But halfway is not where the
    /// eye wants the curve to stop: the picture is of a signal going back to
    /// where it started, so the curve runs to the moment it is back inside a
    /// tenth of resting and the card reports that moment as the return time.
    /// One tolerance for both channels and for `RecoveryProfile`, so the
    /// vertical line on the chart and the "home" band the profile judges by
    /// are the same band.
    static let homeTolerance: Double = 0.10

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
    /// **One minute, not five.** Five was chosen to reject a noisy touch, and
    /// it went on rejecting real recoveries: a treadmill session whose vagal
    /// brake crossed the bar at about twelve minutes, peaked, and then eased
    /// back a little was reported as ">19 min · still recalibrating" — with the
    /// chart directly beneath it showing the trace plainly above the line it
    /// was said not to have reached. A five-minute hold asks the signal to
    /// cross *and stay*, which is a stricter question than the one being
    /// reported, and post-exercise vagal tone oscillates on exactly that scale.
    ///
    /// The measure being reported is a crossing time, so the crossing is what
    /// should end it — every standard index of this shape (HRR60, T30, half-
    /// recovery time) is read at a moment, not sustained. One minute keeps the
    /// only thing the hold was ever needed for, which is refusing a single
    /// noisy sample.
    static let holdMinutes: Double = 1

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

    /// Which way the signal travels as it recovers.
    ///
    /// The vagal brake was pushed down and climbs back; heart rate was pushed
    /// up and falls back. Same question, mirrored — so it is one function with
    /// a direction rather than two implementations that can disagree, which is
    /// how the chart came to print "halfway back 0 minutes" beneath a headline
    /// of ">34 min".
    enum Direction {
        case upward     // Deceleration Capacity
        case downward   // heart rate

        /// How far the session pushed the signal away from resting, as a share
        /// of resting. Zero or negative when it moved the *other* way — a
        /// session that raised the vagal brake has no fall to climb out of.
        func drawdownFraction(pre: Double, extreme: Double) -> Double? {
            guard pre > 0 else { return nil }
            let excursion = self == .upward ? pre - extreme : extreme - pre
            return excursion / pre
        }

        /// Whether the session moved the signal far enough that coming back is
        /// a measurable event rather than a restatement of the noise.
        func movedEnough(pre: Double, extreme: Double) -> Bool {
            (drawdownFraction(pre: pre, extreme: extreme) ?? -1) >= minimumDrawdownFraction
        }

        /// The same question from a view, which holds optional `Float`s.
        func movedEnough(pre: Float?, extreme: Float?) -> Bool {
            guard let pre, let extreme else { return false }
            return movedEnough(pre: Double(pre), extreme: Double(extreme))
        }

        /// Halfway from where it ended up back toward where it started.
        ///
        /// Nil when the excursion was too small to score — see
        /// `minimumDrawdownFraction`. Every caller routes through here, so the
        /// dashed line on the chart, the stored time, the neural percentage and
        /// the composite all fall silent together rather than one of them
        /// inventing a number the others cannot see.
        func target(pre: Double, extreme: Double) -> Double? {
            guard movedEnough(pre: pre, extreme: extreme) else { return nil }
            switch self {
            case .upward:   return extreme + (pre - extreme) * targetFraction
            case .downward: return extreme - (extreme - pre) * targetFraction
            }
        }

        /// The resting band's edge, on the side the signal returns from.
        func homeTarget(pre: Double) -> Double {
            self == .upward ? pre * (1 - homeTolerance) : pre * (1 + homeTolerance)
        }

        func met(_ value: Double, target: Double) -> Bool {
            self == .upward ? value >= target : value <= target
        }

        /// The tolerance band around the bar, on the correct side of it.
        func held(_ value: Double, target: Double) -> Bool {
            self == .upward ? value >= target * holdFraction
                            : value <= target / holdFraction
        }
    }

    /// The one crossing rule. Every caller — the stored score, both charts —
    /// goes through here, so a number and the picture under it cannot be
    /// computed two different ways.
    ///
    /// - Parameter series: (minutes since the session ended, value), any order.
    static func crossing(_ series: [(minutes: Double, value: Double)],
                         target: Double,
                         direction: Direction) -> Outcome {
        let s = series.filter { $0.minutes >= 0 }.sorted { $0.minutes < $1.minutes }
        guard let observed = s.last?.minutes, !s.isEmpty else { return .notObserved }

        // Every crossing is tried, not just the first. A brief touch that falls
        // away is not recovery, but it is also not proof that recovery never
        // came — taking `firstIndex` and giving up on it reported "never" for a
        // session that flickered at three minutes and genuinely returned at
        // twenty.
        for idx in s.indices where direction.met(s[idx].value, target: target) {
            let deadline = s[idx].minutes + holdMinutes
            let window = s[idx...].prefix { $0.minutes <= deadline }
            // A recording that stops inside the window is judged on what it
            // has. Demanding the full five minutes would report failure for a
            // session that recovered and then had the strap taken off.
            if window.allSatisfy({ direction.held($0.value, target: target) }) {
                return .reached(minutes: s[idx].minutes)
            }
        }
        return observed >= minimumObservationMinutes
            ? .notReached(observedMinutes: observed)
            : .notObserved
    }

    /// - Parameter after: (minutes since the session ended, DC), any order.
    /// - Parameter dcTrough: the lowest vagal tone reached during the session.
    ///   Without it there is no fall to measure the climb against.
    static func halfRecovery(after: [(minutes: Double, dc: Double)],
                             dcPre: Double?,
                             dcTrough: Double?) -> Outcome {
        guard let dcPre, dcPre > 0, let dcTrough,
              // A session that never suppressed has no hole to climb out of.
              let target = Direction.upward.target(pre: dcPre, extreme: dcTrough)
        else { return .notObserved }
        return crossing(after.map { (minutes: $0.minutes, value: $0.dc) },
                        target: target, direction: .upward)
    }

    /// The same arc in heart rate: how long to fall halfway back from the peak
    /// toward the pre-session level.
    ///
    /// Scored beside the vagal brake rather than instead of it. Heart rate is
    /// routinely home while vagal tone is still well down, and it needs only
    /// heart rate — so it produces a reading on the sessions where DC cannot be
    /// computed at all, which is exactly when the vagal channel goes blank and
    /// leaves the section with nothing.
    static func heartRateReturn(after: [(minutes: Double, hr: Double)],
                                hrPre: Double?,
                                hrPeak: Double?) -> Outcome {
        guard let hrPre, hrPre > 0, let hrPeak,
              // A session that never raised the pulse has nothing to come down from.
              let target = Direction.downward.target(pre: hrPre, extreme: hrPeak)
        else { return .notObserved }
        return crossing(after.map { (minutes: $0.minutes, value: $0.hr) },
                        target: target, direction: .downward)
    }

    /// How long until the signal was back inside its resting band.
    ///
    /// The same crossing rule and the same excursion floor as the halfway
    /// time, aimed at `Direction.homeTarget` instead — so a session that
    /// barely moved reports nothing here for the same reason it reports
    /// nothing there.
    ///
    /// - Parameter series: (minutes since the session ended, value), any order.
    static func returnToResting(_ series: [(minutes: Double, value: Double)],
                                pre: Double?,
                                extreme: Double?,
                                direction: Direction) -> Outcome {
        guard let pre, pre > 0, let extreme,
              direction.movedEnough(pre: pre, extreme: extreme)
        else { return .notObserved }
        return crossing(series, target: direction.homeTarget(pre: pre), direction: direction)
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

    /// What to say when the session never moved the signal far enough to have
    /// anything to come back from.
    ///
    /// Separate from `summary` on purpose. `.notObserved` reaches the screen
    /// for two unrelated reasons — nothing was recorded, or nothing happened —
    /// and printing "not enough recording after this session" for the second
    /// blames the strap for a quiet session.
    static func noExcursionNote(subject: String, direction: Direction) -> String {
        let verb = direction == .upward ? "drop" : "rise"
        let head = subject.prefix(1).uppercased() + subject.dropFirst()
        return "\(head) did not \(verb) more than a tenth from where it started, "
             + "so there is no rebound to time. That is a reading about the session, "
             + "not a gap in the recording."
    }

    /// The sentence shown under the chart, for the return the curve is drawn to.
    static func returnSummary(_ outcome: Outcome, subject: String) -> String {
        let head = subject.prefix(1).uppercased() + subject.dropFirst()
        switch outcome {
        case let .reached(minutes) where minutes < 1:
            return "\(head) was already back at your resting level when you stopped."
        case let .reached(minutes):
            return "\(head) was back at your resting level \(Int(minutes.rounded())) minutes after you stopped — the curve ends there."
        case let .notReached(observed):
            return "\(head) was still short of your resting level \(Int(observed.rounded())) minutes after you stopped, so the curve runs to the end of the recording."
        case .notObserved:
            return "Not enough recording after this session to see the return."
        }
    }

    /// The sentence shown under the chart.
    ///
    /// - Parameter subject: what came back — "your vagal brake", "your heart
    ///   rate". Both channels print this line, and one of them saying "vagal
    ///   brake" under a heart-rate curve is how a caption starts describing a
    ///   different measurement from the one drawn above it.
    static func summary(_ outcome: Outcome, subject: String = "your vagal brake") -> String {
        switch outcome {
        case let .reached(minutes) where minutes < 1:
            return "\(subject.prefix(1).uppercased() + subject.dropFirst()) was already halfway back when you stopped."
        case let .reached(minutes):
            return "Halfway back to your resting level \(Int(minutes.rounded())) minutes after you stopped."
        case let .notReached(observed):
            return "Still less than halfway back \(Int(observed.rounded())) minutes after you stopped — this one is taking a while to clear."
        case .notObserved:
            return "Not enough recording after this session to see recovery."
        }
    }
}
