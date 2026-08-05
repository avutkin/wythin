import Foundation

/// How fast heart rate fell once you stopped.
///
/// Worth having beside the vagal-tone measures for a practical reason as much
/// as a physiological one: it needs only heart rate. DC requires 150 clean
/// intervals and twenty deceleration anchors, which resistance work frequently
/// cannot supply — so on exactly the sessions where the vagal measures go
/// blank, this still produces a number.
///
/// It also answers a different question. Heart rate is often home while vagal
/// tone is still well down; the distance between the two is the difference
/// between looking recovered and being recovered.
enum HeartRateRecovery {

    /// A session that ended easy has no recovery to measure — heart rate was
    /// already near resting, and any drop is noise. Expressed as a share of the
    /// session's own heart-rate amplitude so it scales with the effort.
    static let minimumEndingIntensity: Double = 0.30

    /// How close to the 60-second mark a sample must be for HRR60 to be honest
    /// rather than extrapolated. Background ticks arrive every 30 s.
    static let hrr60ToleranceSeconds: Double = 20

    // MARK: - HRR60

    /// Beats per minute lost in the first sixty seconds after stopping.
    ///
    /// The classic marker: a larger drop is faster parasympathetic reactivation.
    /// Linearly interpolated between the samples either side of +60 s, and nil
    /// when neither is close enough to interpolate honestly.
    ///
    /// - Parameters:
    ///   - after: (seconds since the session ended, HR), any order.
    ///   - hrAtEnd: heart rate as the session finished.
    ///   - restingHR / peakHR: used only to decide the session ended hard
    ///     enough for a drop to mean anything.
    static func hrr60(after: [(seconds: Double, hr: Double)],
                      hrAtEnd: Double?,
                      restingHR: Double?,
                      peakHR: Double?) -> Double? {
        guard let hrAtEnd, endedHardEnough(hrAtEnd: hrAtEnd,
                                           restingHR: restingHR, peakHR: peakHR) else { return nil }
        guard let at60 = interpolate(after, at: 60) else { return nil }
        return max(hrAtEnd - at60, 0)
    }

    /// True when the session finished at enough intensity for a fall to be
    /// recovery rather than drift.
    static func endedHardEnough(hrAtEnd: Double, restingHR: Double?, peakHR: Double?) -> Bool {
        guard let restingHR, let peakHR, peakHR > restingHR else { return true }
        let amplitude = peakHR - restingHR
        return (hrAtEnd - restingHR) >= amplitude * minimumEndingIntensity
    }

    /// Value at `at` seconds, interpolated between the bracketing samples.
    static func interpolate(_ series: [(seconds: Double, hr: Double)], at: Double) -> Double? {
        let s = series.filter { $0.seconds >= 0 }.sorted { $0.seconds < $1.seconds }
        guard !s.isEmpty else { return nil }
        if let exact = s.first(where: { abs($0.seconds - at) < 0.001 }) { return exact.hr }

        let before = s.last  { $0.seconds <= at }
        let after  = s.first { $0.seconds >= at }
        switch (before, after) {
        case let (b?, a?) where a.seconds > b.seconds:
            let t = (at - b.seconds) / (a.seconds - b.seconds)
            return b.hr + (a.hr - b.hr) * t
        case let (b?, nil):
            // Recording stopped before the mark. Only usable if it stopped
            // close to it — otherwise this would be extrapolation dressed up
            // as measurement.
            return abs(at - b.seconds) <= hrr60ToleranceSeconds ? b.hr : nil
        case let (nil, a?):
            return abs(a.seconds - at) <= hrr60ToleranceSeconds ? a.hr : nil
        default:
            return nil
        }
    }

    // MARK: - T30

    /// Short-term time constant of heart-rate decay, in seconds, from the first
    /// thirty seconds after stopping.
    ///
    /// The negative reciprocal of the slope of a linear fit of ln(HR) against
    /// time. Smaller is faster reactivation. It reaches further into the very
    /// early recovery than HRR60 can, and being pure heart rate it carries no
    /// artifact sensitivity at all.
    static func t30(after: [(seconds: Double, hr: Double)],
                    restingHR: Double? = nil,
                    peakHR: Double? = nil) -> Double? {
        let window = after
            .filter { $0.seconds >= 0 && $0.seconds <= 30 && $0.hr > 0 }
            .sorted { $0.seconds < $1.seconds }
        guard window.count >= 3 else { return nil }
        if let first = window.first?.hr,
           !endedHardEnough(hrAtEnd: first, restingHR: restingHR, peakHR: peakHR) { return nil }

        let n  = Double(window.count)
        let mx = window.reduce(0) { $0 + $1.seconds } / n
        let my = window.reduce(0) { $0 + log($1.hr) } / n
        var num = 0.0, den = 0.0
        for p in window {
            num += (p.seconds - mx) * (log(p.hr) - my)
            den += (p.seconds - mx) * (p.seconds - mx)
        }
        guard den > 0 else { return nil }
        let slope = num / den
        // A flat or rising trace has no decay constant to report.
        guard slope < 0 else { return nil }
        return -1 / slope
    }

    // MARK: - Scoring

    /// A drop of this many bpm in the first minute is as fast as this gets,
    /// and this few is as slow. Anchored rather than ranked against history so
    /// the number means the same thing on the first session as on the fiftieth.
    static let fastHRR60: Double = 40
    static let slowHRR60: Double = 10

    static func score(hrr60: Double?) -> Int? {
        guard let hrr60 else { return nil }
        let t = (hrr60 - slowHRR60) / (fastHRR60 - slowHRR60)
        return Int((100 * min(max(t, 0), 1)).rounded())
    }
}
