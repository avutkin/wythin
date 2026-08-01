import Foundation

/// Which physiological domain a moment of exercise sat in, read from the
/// fractal correlation of the heartbeat rather than from a heart-rate zone.
///
/// DFA α1 crosses 0.75 at the aerobic threshold and 0.5 entering the severe
/// domain. Because those boundaries are internal, they need no maximum heart
/// rate and no lab: two people at the same 148 bpm can be in different
/// domains, and a heart-rate zone cannot tell them apart.
enum IntensityDomain: Hashable {
    case moderate
    case heavy
    case severe
}

/// %HR-reserve, intensity domains and session Load. Pure and unit-tested.
enum ExerciseIntensity {

    // MARK: - Thresholds

    /// DFA α1 at or above this is the moderate domain.
    static let moderateFloor: Double = 0.75

    /// DFA α1 at or above this — and below `moderateFloor` — is the heavy domain.
    static let heavyFloor: Double = 0.50

    /// Banister exponential weighting. The published constants are 1.92 (male)
    /// and 1.67 (female); 1.8 is a fixed compromise because the app holds no
    /// sex. It may become a profile setting later; it is deliberately not one
    /// now, rather than asking for a datum the model barely needs.
    static let loadWeighting: Double = 1.8

    /// Gaps longer than this are strap dropout, not work, and contribute no
    /// load. Background ticks arrive every 30 s, so 90 s tolerates ordinary
    /// jitter without integrating a lunch break as exercise.
    static let maxGapSeconds: TimeInterval = 90

    /// Subtypes whose chest-strap motion is roughly proportional to mechanical
    /// work, and can therefore serve as an Efficiency denominator.
    ///
    /// The exclusions are the point: a heavy single moves the chest less than a
    /// light set of ten, so lifting motion is uncorrelated with load. Cycling
    /// and swimming barely move the sternum at all. Those get no Efficiency
    /// score rather than a fabricated one.
    static let motionBearingSubtypes: Set<String> = [
        "Easy Run", "Tempo Run", "Intervals", "Long Run", "Trail Run",
        "HIIT", "Boxing", "Rowing", "CrossFit",
        "Nature Walk", "City Walk", "Hiking", "Treadmill",
    ]

    // MARK: - Intensity

    /// Fraction of the heart-rate reserve in use, 0…1.
    static func hrReserve(hr: Float, restingHR: Float, ceiling: Float) -> Double {
        let span = Double(ceiling - restingHR)
        guard span > 0 else { return 0 }
        return min(max(Double(hr - restingHR) / span, 0), 1)
    }

    // MARK: - Load

    /// Session load: the HR-reserve impulse with Banister exponential
    /// weighting, integrated across the sample series.
    ///
    /// Unitless by design — it is a magnitude to compare against your own other
    /// sessions, not a physical quantity. An easy 30-minute walk lands near 14
    /// and a hard hour near 150.
    ///
    /// Load is the only descriptive number in the model. Because it carries the
    /// size of the stimulus, none of the three axes has to, which is what frees
    /// all of them to point the same way.
    static func load(samples: [(date: Date, hr: Float)],
                     restingHR: Float,
                     ceiling: Float) -> Double {
        guard samples.count >= 2 else { return 0 }
        let sorted = samples.sorted { $0.date < $1.date }
        var total = 0.0
        for i in 0..<(sorted.count - 1) {
            let dt = sorted[i + 1].date.timeIntervalSince(sorted[i].date)
            guard dt > 0, dt <= maxGapSeconds else { continue }
            let x = hrReserve(hr: sorted[i].hr, restingHR: restingHR, ceiling: ceiling)
            total += x * exp(loadWeighting * x) * (dt / 60)
        }
        return total
    }

    // MARK: - Domains

    static func domain(dfa1: Double) -> IntensityDomain {
        if dfa1 >= moderateFloor { return .moderate }
        if dfa1 >= heavyFloor    { return .heavy }
        return .severe
    }

    /// Seconds spent in each domain.
    ///
    /// Each sample owns the interval forward to the next one; the final sample
    /// carries no forward duration, and gaps beyond `maxGapSeconds` are dropped
    /// on the same reasoning as `load`.
    static func domainSplit(samples: [(date: Date, dfa1: Double)]) -> [IntensityDomain: TimeInterval] {
        guard samples.count >= 2 else { return [:] }
        let sorted = samples.sorted { $0.date < $1.date }
        var split: [IntensityDomain: TimeInterval] = [:]
        for i in 0..<(sorted.count - 1) {
            let dt = sorted[i + 1].date.timeIntervalSince(sorted[i].date)
            guard dt > 0, dt <= maxGapSeconds else { continue }
            split[domain(dfa1: sorted[i].dfa1), default: 0] += dt
        }
        return split
    }
}
