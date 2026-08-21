import Foundation

/// The session's recovery as three layers and one time, read from the samples
/// after the session rather than from stored scalars.
///
/// **Why three layers.** Cardiovascular load coming down and parasympathetic
/// control returning are different processes on different timescales, and they
/// diverge: heart rate is routinely home while vagal regulation is still well
/// down. One blended "recovered" number reports whichever of the two it happened
/// to be built from. The third layer — physical recovery — is not measurable
/// from an ECG at all, and is named here so that a high autonomic reading is
/// never read as permission to train.
enum RecoveryProfile {

    /// One post-session sample. Either channel may be missing at any tick.
    struct Sample: Equatable {
        let minutes: Double     // since the session ended
        let hr:      Double?
        let dc:      Double?

        init(minutes: Double, hr: Double?, dc: Double?) {
            self.minutes = minutes
            self.hr = hr
            self.dc = dc
        }
    }

    /// Where the cardiovascular channel counts as home: within a tenth of the
    /// pre-session resting rate. A stricter bar than the halfway mark the
    /// timing channels use, because this one is claiming the load is *gone*
    /// rather than that it is coming down.
    static let restingTolerance: Double = 1.10

    /// The checkpoint both layer percentages are read at.
    static let profileMinutes: Double = 10

    struct Result: Equatable {
        /// How far heart rate came back toward resting, 0–100.
        let cardiovascular: Int?
        /// How far the vagal brake climbed out of its trough, 0–100.
        let neural: Int?
        /// Did it come back and stay back, 0–100.
        let stability: Int?
        /// Minutes until both channels were home together and held.
        let timeToStable: RecoveryTiming.Outcome

        /// Physical recovery is not measurable from an ECG. The field exists so
        /// the display cannot quietly omit the layer and let the other two read
        /// as whole-body readiness.
        var physical: Int? { nil }
    }

    // MARK: - Build

    static func build(after: [Sample],
                      restingHR: Double?,
                      peakHR: Double?,
                      dcPre: Double?,
                      dcTrough: Double?) -> Result {
        let series = after.filter { $0.minutes >= 0 }.sorted { $0.minutes < $1.minutes }

        return Result(
            cardiovascular: cardiovascularPercent(series, restingHR: restingHR, peakHR: peakHR),
            neural: neuralPercent(series, dcPre: dcPre, dcTrough: dcTrough),
            stability: stabilityPercent(series),
            timeToStable: timeToStable(series, restingHR: restingHR,
                                       dcPre: dcPre, dcTrough: dcTrough))
    }

    /// The share of the heart-rate excursion that had been given back by the
    /// ten-minute mark.
    static func cardiovascularPercent(_ series: [Sample],
                                      restingHR: Double?,
                                      peakHR: Double?) -> Int? {
        guard let restingHR, let peakHR, peakHR > restingHR,
              let hr = value(series, at: profileMinutes, \.hr) else { return nil }
        return clamped((peakHR - hr) / (peakHR - restingHR))
    }

    /// The share of the vagal fall that had been climbed back by then.
    static func neuralPercent(_ series: [Sample],
                              dcPre: Double?,
                              dcTrough: Double?) -> Int? {
        guard let dcPre, let dcTrough, dcPre > dcTrough,
              let dc = value(series, at: profileMinutes, \.dc) else { return nil }
        return clamped((dc - dcTrough) / (dcPre - dcTrough))
    }

    /// Did it come back and *stay* back.
    ///
    /// A trace that returns and then bounces is a different result from one
    /// that returns and settles, and the halfway time cannot tell them apart —
    /// both cross once. This counts the share of samples holding at or better
    /// than the best level reached so far: heart rate near its running minimum,
    /// the brake near its running maximum, the two averaged.
    static let stabilitySlack: Double = 0.05

    static func stabilityPercent(_ series: [Sample]) -> Int? {
        func share(_ values: [Double], improvingUpward: Bool) -> Double? {
            guard values.count >= 3 else { return nil }
            var best = values[0]
            var held = 0
            for v in values.dropFirst() {
                if improvingUpward {
                    best = max(best, v)
                    if v >= best * (1 - stabilitySlack) { held += 1 }
                } else {
                    best = min(best, v)
                    if v <= best * (1 + stabilitySlack) { held += 1 }
                }
            }
            return Double(held) / Double(values.count - 1)
        }

        let hr = share(series.compactMap(\.hr), improvingUpward: false)
        let dc = share(series.compactMap(\.dc), improvingUpward: true)
        let present = [hr, dc].compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return clamped(present.reduce(0, +) / Double(present.count))
    }

    /// Minutes until **both** channels were home at once, and stayed for
    /// `RecoveryTiming.holdMinutes`.
    ///
    /// Requiring both is deliberate and costs resolution: on a hard session it
    /// frequently ends as a bound rather than a number. That is the honest
    /// answer — the session was still recalibrating when the recording stopped —
    /// and the display pairs the bound with what is typical for the load rather
    /// than leaving it to read as a failure.
    static func timeToStable(_ series: [Sample],
                             restingHR: Double?,
                             dcPre: Double?,
                             dcTrough: Double?) -> RecoveryTiming.Outcome {
        guard let restingHR,
              let dcPre, let dcTrough,
              let vagalBar = RecoveryTiming.Direction.upward.target(pre: dcPre, extreme: dcTrough),
              let observed = series.last?.minutes
        else { return .notObserved }

        let hrBar = restingHR * restingTolerance
        func home(_ s: Sample) -> Bool {
            guard let hr = s.hr, let dc = s.dc else { return false }
            return hr <= hrBar && dc >= vagalBar
        }
        // The hold is judged with the same tolerance the timing channels use, so
        // a single noisy tick does not un-recover a settled session.
        func heldAt(_ s: Sample) -> Bool {
            guard let hr = s.hr, let dc = s.dc else { return true }
            return hr <= hrBar / RecoveryTiming.holdFraction
                && dc >= vagalBar * RecoveryTiming.holdFraction
        }

        for idx in series.indices where home(series[idx]) {
            let deadline = series[idx].minutes + RecoveryTiming.holdMinutes
            let window = series[idx...].prefix { $0.minutes <= deadline }
            if window.allSatisfy(heldAt) {
                return .reached(minutes: series[idx].minutes)
            }
        }
        return observed >= RecoveryTiming.minimumObservationMinutes
            ? .notReached(observedMinutes: observed)
            : .notObserved
    }

    // MARK: - Helpers

    /// The channel's value at `at` minutes, from the nearest sample within two
    /// minutes of the mark. Nil rather than extrapolated when nothing is close.
    static func value(_ series: [Sample], at: Double,
                      _ channel: KeyPath<Sample, Double?>) -> Double? {
        let candidates = series.filter { $0[keyPath: channel] != nil }
        guard let nearest = candidates.min(by: {
            abs($0.minutes - at) < abs($1.minutes - at)
        }), abs(nearest.minutes - at) <= 2 else { return nil }
        return nearest[keyPath: channel]
    }

    private static func clamped(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}

/// What is typical at this load, so a bound reads as a finding rather than as
/// an error message.
///
/// Orienting expectations only, from the post-exercise reactivation literature
/// (Stanley, Peake & Buchheit, *Sports Medicine* 2013) — never a target, and
/// replaced by the person's own matched sessions once there are enough of them.
enum RecoveryExpectation {

    enum Band: String {
        case moderate, heavy, severe

        var label: String {
            switch self {
            case .moderate: return "a moderate session"
            case .heavy:    return "a heavy session"
            case .severe:   return "a severe session"
            }
        }

        /// Typical minutes for the vagal brake to come halfway back.
        var vagalHalfway: String {
            switch self {
            case .moderate: return "5–15 min"
            case .heavy:    return "15–45 min"
            case .severe:   return "often longer than one recording"
            }
        }
    }

    /// The band this session sat in, from the intensity domain it spent most of
    /// its time in. Available on the very first session, since it needs no
    /// history to compute.
    static func band(moderateSec: Double, heavySec: Double, severeSec: Double) -> Band? {
        let total = moderateSec + heavySec + severeSec
        guard total > 0 else { return nil }
        if severeSec >= heavySec && severeSec >= moderateSec { return .severe }
        if heavySec >= moderateSec { return .heavy }
        return .moderate
    }

    static func sentence(for band: Band) -> String {
        "typical for \(band.label): \(band.vagalHalfway)"
    }
}
